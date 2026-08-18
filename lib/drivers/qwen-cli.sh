#!/bin/bash
# shellcheck disable=SC2034
# Agent driver: Qwen Code CLI
# Implements the role interface for Alibaba's Qwen Code CLI.

# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

agent_default_model() { echo "qwen3.8-max"; }
agent_name()    { echo "Qwen Code CLI"; }
agent_cmd()     { echo "qwen"; }

agent_version() {
    local v
    v=$(qwen --version 2>/dev/null || echo "unknown")
    # `qwen --version` prints a bare version number ("0.21.5").
    echo "${v%% *}"
}

# Write ~/.qwen/settings.json for API-key auth.
# Mirrors what `bl config agent --agent qwen-code` writes on a
# ModelStudio setup: one openai-protocol provider entry per model,
# key read from the env var named by envKey, openai selected as the
# auth type so no interactive /auth is needed.  Without this file
# qwen falls back to its built-in defaults, which point at the
# China (cn-beijing) endpoint and return 401 for international
# accounts.
# Args: <model>
_qwen_write_settings() {
    local model="$1"
    local model_id="${model##*/}"
    mkdir -p "${HOME}/.qwen"
    jq -n \
        --arg id "$model_id" \
        --arg base "${QWEN_BASE_URL:-}" \
        --arg effort "${QWEN_REASONING_EFFORT:-}" \
        --arg cw "${QWEN_CONTEXT_WINDOW:-}" '
        {
            modelProviders: { openai: [
                ({ id: $id, name: $id, envKey: "DASHSCOPE_API_KEY" }
                 + (if $base != "" then { baseUrl: $base } else {} end)
                 + (if $cw != "" then
                        { generationConfig:
                            { contextWindowSize: ($cw | tonumber) } }
                    else {} end))
            ] },
            security: { auth: { selectedType: "openai" } },
            model: ({ name: $id }
                    + (if $effort != "" then
                           { reasoningEffort: $effort }
                       else {} end))
        }' > "${HOME}/.qwen/settings.json"
}

# Run one agent session.
# Args: <model> <prompt_text> <logfile> [append_system_prompt_file]
agent_run() {
    local model="$1" prompt_text="$2" logfile="$3"
    local append_file="${4:-}"

    local -a args=(
        -p "$prompt_text"
        --output-format stream-json
        --yolo
    )

    # With DASHSCOPE_API_KEY set (apikey auth) the container has no
    # host qwen config, so synthesize settings.json from the env and
    # target the provider entry by id (provider prefix stripped).
    # Without a key, the mounted host config owns the model aliases
    # and the swarmfile alias is passed verbatim.
    if [ -n "${DASHSCOPE_API_KEY:-}" ]; then
        _qwen_write_settings "$model"
        args+=(-m "${model##*/}")
    else
        args+=(-m "$model")
    fi

    # qwen has --append-system-prompt but it takes the text, not a
    # file path, so inline the instructions.
    if [ -n "$append_file" ] && [ -f "$append_file" ]; then
        args+=(--append-system-prompt "$(cat "$append_file")")
    fi

    # _run_reaped puts qwen in its own process group and SIGKILLs
    # the group after qwen exits, so surviving children can't keep
    # the downstream activity-filter pipeline blocked by holding
    # stdout.
    _run_reaped "$logfile" qwen "${args[@]}"
}

# Start Qwen Code CLI's native interactive UI.
# Args: <model> <prompt_file> [append_system_prompt_file]
agent_interactive_run() {
    local model="$1" prompt_file="${2:-}" append_file="${3:-}"

    local -a args=(--yolo)
    if [ -n "${DASHSCOPE_API_KEY:-}" ]; then
        _qwen_write_settings "$model"
        args+=(-m "${model##*/}")
    else
        args+=(-m "$model")
    fi

    if [ -n "$append_file" ] && [ -f "$append_file" ]; then
        args+=(--append-system-prompt "$(cat "$append_file")")
    fi

    if [ -n "$prompt_file" ] && [ -f "$prompt_file" ]; then
        printf 'Profile prompt is available at %s\n' "$prompt_file"
    fi

    qwen "${args[@]}"
}

# Write agent-specific settings and authenticate.
agent_settings() {
    local _workspace="$1"
    local qwen_home="${HOME}/.qwen"
    local staged_home="${HOME}/.qwen-host"

    # oauth auth mounts the host qwen dir read-only at the staged
    # path.  The CLI writes sessions and logs into its home dir, so
    # it gets a private writable copy instead of the mount itself.
    if [ -d "$staged_home" ] && [ ! -e "$qwen_home" ]; then
        cp -r "$staged_home" "$qwen_home"
    fi

    # Qwen reads AGENTS.md/QWEN.md for project instructions, not
    # .claude/CLAUDE.md.  Bridge the gap when AGENTS.md is absent.
    if [ ! -f "${_workspace}/AGENTS.md" ] \
            && [ ! -f "${_workspace}/QWEN.md" ]; then
        local _src=""
        [ -f "${_workspace}/.claude/CLAUDE.md" ] \
            && _src="${_workspace}/.claude/CLAUDE.md"
        [ -z "$_src" ] && [ -f "${_workspace}/CLAUDE.md" ] \
            && _src="${_workspace}/CLAUDE.md"
        if [ -n "$_src" ]; then
            cp "$_src" "${_workspace}/AGENTS.md"
            mkdir -p "${_workspace}/.git/info"
            echo "AGENTS.md" >> "${_workspace}/.git/info/exclude"
        fi
    fi

    # Qwen reads project skills from .qwen/skills/, not
    # .claude/skills/.  Symlink when the Qwen location is absent.
    # Only fires when .claude/skills/ exists (context=full);
    # slim/none strip it so this is a no-op.
    if [ ! -d "${_workspace}/.qwen/skills" ] \
        && [ -d "${_workspace}/.claude/skills" ]; then
        mkdir -p "${_workspace}/.qwen"
        ln -s "../.claude/skills" "${_workspace}/.qwen/skills"
        mkdir -p "${_workspace}/.git/info"
        echo ".qwen/skills" >> "${_workspace}/.git/info/exclude"
    fi
}

# Extract stats from a Qwen stream-json log.
# The terminal result object carries usage in the same shape the
# shared JSONL parser expects (input_tokens, output_tokens,
# cache_read_input_tokens), plus duration_ms.  It has no cost field
# and may lack num_turns; cost stays 0 (the swarmfile pricing map
# covers it) and turns falls back to counting assistant messages.
agent_extract_stats() {
    local logfile="$1"
    local stats turns
    stats=$(_extract_jsonl_stats "$logfile")
    turns="${stats##*$'\t'}"
    if [ "${turns:-0}" = "0" ]; then
        turns=$(grep -c '"type"[[:space:]]*:[[:space:]]*"assistant"' \
            "$logfile" 2>/dev/null || true)
        stats="${stats%$'\t'*}	${turns:-0}"
    fi

    # qwen folds cache reads into usage.input_tokens: its total_tokens
    # is input + output, so a session whose cache_read_input_tokens
    # nearly equals input_tokens spent almost nothing on fresh input
    # (verified against real session logs; qwen reports no
    # cache-creation bucket).  The pricing map expects Claude's
    # disjoint buckets, where input_tokens excludes cache reads, so
    # subtract them here -- in the qwen driver only, the shared parser
    # stays generic -- or cache reads are billed twice.
    local cost tok_in tok_out cache_rd tail
    cost="${stats%%$'\t'*}"
    tail="${stats#*$'\t'}"
    tok_in="${tail%%$'\t'*}"
    tail="${tail#*$'\t'}"
    tok_out="${tail%%$'\t'*}"
    tail="${tail#*$'\t'}"
    cache_rd="${tail%%$'\t'*}"
    tail="${tail#*$'\t'}"
    tok_in=$(( tok_in - cache_rd ))
    if [ "$tok_in" -lt 0 ]; then
        tok_in=0
    fi
    printf '%s\t%s\t%s\t%s\t%s' \
        "$cost" "$tok_in" "$tok_out" "$cache_rd" "$tail"
}

# Return the jq program for parsing activity from Qwen stream-json.
# The schema mirrors Claude Code's: assistant messages carry
# content blocks of type thinking/text/tool_use, with tool inputs
# as objects.  Tool names are the gemini-cli heritage ones
# (run_shell_command, read_file, edit, ...).
agent_activity_jq() {
    cat <<'JQ'
def truncate(n):
  if length > n then .[:n-3] + "..." else . end;

def first_line:
  split("\n")[0] // .;

def ts:
  now | strftime("%H:%M:%S");

def prefix:
  "\u001b[33m\(ts)   agent[\($id)]";

def reset:
  "\u001b[0m";

fromjson? // empty |
select(.type == "assistant") |
.message.content[]? |
if .type == "thinking" then
  ((.thinking // "") | first_line | truncate(80)) as $s |
  if ($s | length) > 0 then
    "\(prefix) Think: " + $s + reset
  else empty end
elif .type == "tool_use" then
  (.input.file_path // .input.absolute_path // .input.path // "") as $p |
  if   .name == "run_shell_command" then "\(prefix) Shell: " + ((.input.command // "") | first_line | truncate(80)) + reset
  elif .name == "read_file"  then "\(prefix) Read "  + $p + reset
  elif .name == "write_file" then "\(prefix) Write " + $p + reset
  elif .name == "edit"       then "\(prefix) Edit "  + $p + reset
  elif .name == "glob"       then "\(prefix) Glob "  + (.input.pattern // "") + reset
  elif .name == "grep_search" then "\(prefix) Grep " + (.input.pattern // "") + reset
  elif .name == "web_search" then "\(prefix) Search: " + (.input.query // "") + reset
  elif .name == "web_fetch"  then "\(prefix) Fetch " + (.input.url // "") + reset
  elif .name == "agent"      then "\(prefix) Agent: " + ((.input.description // .input.prompt // "") | first_line | truncate(60)) + reset
  else "\(prefix) " + (.name // "unknown") + reset
  end
else empty
end
JQ
}

# Detect fatal errors in a Qwen session log.
# A failed run ends with a result object carrying is_error:true;
# provider quota/rate failures are reported as a *successful* result
# whose text carries the error; startup failures (bad key,
# unreachable endpoint) may surface only on stderr with no
# assistant messages on stdout.
agent_detect_fatal() {
    local logfile="$1"

    local result_line is_err
    result_line=$(grep '"type"[[:space:]]*:[[:space:]]*"result"' \
        "$logfile" 2>/dev/null | tail -1 || true)
    if [ -n "$result_line" ]; then
        is_err=$(echo "$result_line" \
            | jq -r '.is_error // false' 2>/dev/null || true)
        if [ "$is_err" = "true" ]; then
            echo "$result_line" \
                | jq -r '.result // .error // "unknown error"' \
                    2>/dev/null
            return
        fi

        # qwen-code reports provider quota/rate failures as a
        # *successful* result (is_error:false, exit 0) with the error
        # as the result text (observed on token-plan exhaustion:
        # "Quota exhausted: ... (cause: insufficient_quota: 429 ...)").
        # Surface the strong provider-error phrases so the harness
        # enters its backoff loop instead of counting the session as
        # a successful idle one.  Kept deliberately narrow: a finding
        # report may legitimately mention "rate limit" in prose.
        local result_text
        result_text=$(echo "$result_line" \
            | jq -r '.result // empty' 2>/dev/null || true)
        if printf '%s' "$result_text" \
                | grep -qi 'quota exhausted\|insufficient_quota'; then
            printf '%s\n' "$result_text" | head -1
            return
        fi
    fi

    if [ -f "${logfile}.err" ]; then
        local err_msg
        err_msg=$(grep -i 'error\|invalid.*key\|unauthorized' \
            "${logfile}.err" 2>/dev/null \
            | head -1 || true)
        if [ -n "$err_msg" ] && \
                ! grep -q '"type"[[:space:]]*:[[:space:]]*"assistant"' \
                "$logfile" 2>/dev/null; then
            echo "$err_msg"
        fi
    fi
}

# Detect retriable errors.
# Returns non-empty string if the error is retriable, empty if fatal.
# Args: <logfile> <exit_code>
agent_is_retriable() {
    local logfile="$1"
    local _rate='429\|rate.limit\|too many requests\|quota\|usage.limit\|hit your.*limit\|throttling'
    local _transient='connection reset\|connection closed\|connection refused\|gateway timeout\|bad gateway\|service unavailable\|\b50[234]\b\|timed out\|temporarily unavailable\|at capacity\|overloaded'
    for f in "$logfile" "${logfile}.err"; do
        [ -f "$f" ] || continue
        grep -qi "$_rate" "$f" 2>/dev/null \
            && echo "rate_limited" && return
        grep -qi "$_transient" "$f" 2>/dev/null \
            && echo "transient" && return
    done
    return 0
}

# Map effort to Qwen's reasoning-effort settings key.
# The settings writer picks QWEN_REASONING_EFFORT up when it
# synthesizes settings.json (model.reasoningEffort).  Qwen's
# unified ladder is low|medium|high|xhigh|max; for DashScope-backed
# qwen models any set tier currently collapses to
# enable_thinking:true.
# Args: <effort>
agent_docker_env() {
    local effort="${1:-}"
    if [ -n "$effort" ]; then
        printf -- '-e\nQWEN_REASONING_EFFORT=%s\n' "$effort"
    fi
}

# Resolve auth credentials and emit Docker flags.
# Args: <api_key> <auth_token> <auth_mode> <base_url>
# Reads host env: QWEN_API_KEY, DASHSCOPE_API_KEY, QWEN_HOME,
#                 QWEN_CONTEXT_WINDOW
#
# Auth modes:
#   oauth   — Mount the host qwen dir (~/.qwen) after `qwen` /auth
#             or `bl config agent` on the host.
#   apikey  — Forward the key as DASHSCOPE_API_KEY; the driver
#             synthesizes ~/.qwen/settings.json from the env.
#   (empty) — Auto-detect: API key if set, qwen dir if found.
agent_docker_auth() {
    local api_key="$1" _auth_token="$2" auth_mode="$3" base_url="$4"

    local label=""
    local key="${api_key:-${QWEN_API_KEY:-${DASHSCOPE_API_KEY:-}}}"
    local host_home="${QWEN_HOME:-${HOME}/.qwen}"

    # Use --mount instead of -v so Docker errors out (rather than
    # silently creating a directory) if the source path is missing.
    # Read-only: agent_settings copies it to a writable
    # container-local home before the first session.
    local _mount_fmt='--mount\ntype=bind,source=%s,target=/home/agent/.qwen-host,readonly\n'

    case "${auth_mode}" in
        oauth)
            if [ -d "$host_home" ]; then
                printf -- "$_mount_fmt" "$host_home"
                label="oauth"
            else
                echo "WARNING: auth=oauth but ${host_home} not found" >&2
            fi
            ;;
        apikey)
            if [ -n "$key" ]; then
                printf -- '-e\nDASHSCOPE_API_KEY=%s\n' "$key"
                label="key"
            fi
            ;;
        *)
            if [ -n "$key" ]; then
                printf -- '-e\nDASHSCOPE_API_KEY=%s\n' "$key"
                label="key"
            fi
            if [ -d "$host_home" ]; then
                printf -- "$_mount_fmt" "$host_home"
                if [ -n "$label" ]; then label="auto"
                else label="oauth"; fi
            fi
            ;;
    esac

    if [ -n "$base_url" ]; then
        printf -- '-e\nQWEN_BASE_URL=%s\n' "$base_url"
    fi

    # Optional context-window override, picked up by the settings
    # writer for the synthesized provider entry (e.g. 1000000 for
    # qwen3.8-max's 1M window).
    if [ -n "${QWEN_CONTEXT_WINDOW:-}" ]; then
        printf -- '-e\nQWEN_CONTEXT_WINDOW=%s\n' "$QWEN_CONTEXT_WINDOW"
    fi

    # Headless runs always pass --yolo; silence the one-line
    # no-sandbox startup warning (the container is the sandbox).
    printf -- '-e\nQWEN_CODE_SUPPRESS_YOLO_WARNING=1\n'
    printf -- '-e\nSWARM_AUTH_MODE=%s\n' "$label"
}

# Dockerfile fragment to install this agent's CLI.
# QWEN_CLI_VERSION is a Docker build-arg; empty = latest.
agent_install_cmd() {
    cat <<'INSTALL'
RUN curl -fsSL https://qwen-code-assets.oss-cn-hangzhou.aliyuncs.com/installation/install-qwen-standalone.sh -o /tmp/qwen-install.sh \
    && QWEN_INSTALL_ROOT=/usr/local QWEN_NO_MODIFY_PATH=1 \
       QWEN_INSTALL_METHOD=standalone \
       QWEN_INSTALL_VERSION="${QWEN_CLI_VERSION:-latest}" \
       bash /tmp/qwen-install.sh \
    && rm /tmp/qwen-install.sh
INSTALL
}
