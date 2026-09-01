#!/bin/bash
# shellcheck disable=SC2034
# Agent driver: Kimi Code CLI
# Implements the role interface for Moonshot AI's Kimi Code CLI.

# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

agent_default_model() { echo "kimi-code/kimi-for-coding"; }
agent_name()    { echo "Kimi Code CLI"; }
agent_cmd()     { echo "kimi"; }

agent_version() {
    local v
    v=$(kimi --version 2>/dev/null || echo "unknown")
    # `kimi --version` prints a bare version number ("0.28.0").
    echo "${v%% *}"
}

# Run one agent session.
# Args: <model> <prompt_text> <logfile> [append_system_prompt_file]
agent_run() {
    local model="$1" prompt_text="$2" logfile="$3"
    local append_file="${4:-}"

    # kimi has no --append-system-prompt flag; inline the instructions.
    if [ -n "$append_file" ] && [ -f "$append_file" ]; then
        prompt_text="$(cat "$append_file")"$'\n\n'"$prompt_text"
    fi

    # With KIMI_MODEL_API_KEY set (apikey auth) the CLI synthesizes an
    # in-memory provider from KIMI_MODEL_* and makes it the default
    # model; passing -m <alias> would fail because the swarmfile alias
    # is not in the container's config.toml.  KIMI_MODEL_NAME is the
    # model id sent to the API, so strip the provider prefix from
    # aliases like kimi-code/kimi-for-coding.
    local model_args=()
    if [ -n "${KIMI_MODEL_API_KEY:-}" ]; then
        export KIMI_MODEL_NAME="${KIMI_MODEL_NAME:-${model##*/}}"
    else
        model_args=(-m "$model")
    fi

    # No --yolo here: kimi rejects --prompt combined with --yolo,
    # --auto, or --plan.  Headless mode already runs under the auto
    # permission policy, so there is nothing to opt into.
    #
    # _run_reaped puts kimi in its own process group and SIGKILLs
    # the group after kimi exits, so surviving children can't keep
    # the downstream activity-filter pipeline blocked by holding
    # stdout.
    _run_reaped "$logfile" kimi \
        -p "$prompt_text" \
        --output-format stream-json \
        "${model_args[@]+"${model_args[@]}"}"
}

# Start Kimi Code CLI's native interactive UI.
# Args: <model> <prompt_file> [append_system_prompt_file]
agent_interactive_run() {
    local model="$1" prompt_file="${2:-}" append_file="${3:-}"

    if [ -n "$append_file" ] && [ -f "$append_file" ] \
            && [ ! -f /workspace/AGENTS.md ]; then
        cp "$append_file" /workspace/AGENTS.md 2>/dev/null || true
        mkdir -p /workspace/.git/info
        echo "AGENTS.md" >> /workspace/.git/info/exclude
    fi

    if [ -n "$prompt_file" ] && [ -f "$prompt_file" ]; then
        printf 'Profile prompt is available at %s\n' "$prompt_file"
    fi

    local model_args=()
    if [ -n "${KIMI_MODEL_API_KEY:-}" ]; then
        export KIMI_MODEL_NAME="${KIMI_MODEL_NAME:-${model##*/}}"
    else
        model_args=(-m "$model")
    fi

    kimi --yolo "${model_args[@]+"${model_args[@]}"}"
}

# Write agent-specific settings and authenticate.
agent_settings() {
    local _workspace="$1"
    local kimi_home="${HOME}/.kimi-code"
    local staged_home="${HOME}/.kimi-code-host"

    # oauth auth mounts the host data dir read-only at the staged
    # path.  The CLI writes sessions and logs into its data dir, so
    # it gets a private writable copy instead of the mount itself.
    if [ -d "$staged_home" ] && [ ! -e "$kimi_home" ]; then
        cp -r "$staged_home" "$kimi_home"
    fi

    # Kimi reads AGENTS.md for project instructions, not
    # .claude/CLAUDE.md.  Bridge the gap when AGENTS.md is absent.
    if [ ! -f "${_workspace}/AGENTS.md" ]; then
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

    # Kimi reads skills from .agents/skills/, not .claude/skills/.
    # Symlink when the Kimi location is absent (Kimi supports
    # symlinked skill folders).  Only fires when .claude/skills/
    # exists (context=full); slim/none strip it so this is a no-op.
    if [ ! -d "${_workspace}/.agents/skills" ] \
        && [ -d "${_workspace}/.claude/skills" ]; then
        mkdir -p "${_workspace}/.agents"
        ln -s "../.claude/skills" "${_workspace}/.agents/skills"
        mkdir -p "${_workspace}/.git/info"
        echo ".agents/" >> "${_workspace}/.git/info/exclude"
    fi
}

# Extract stats from a Kimi stream-json log.
# stream-json emits only assistant, tool, and meta objects -- no
# usage or cost summary (verified against kimi-code 0.28.0).  Token
# and cost fields stay 0; cost comes from the swarmfile pricing map.
# turns counts assistant messages, the only per-step signal in the
# stream.
agent_extract_stats() {
    local logfile="$1"
    local turns
    turns=$(grep -c '"role"[[:space:]]*:[[:space:]]*"assistant"' \
        "$logfile" 2>/dev/null || true)
    turns="${turns:-0}"
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s" \
        "0" "0" "0" "0" "0" "0" "0" "$turns"
}

# Return the jq program for parsing activity from Kimi stream-json.
# Tool calls ride on assistant messages as tool_calls[]; arguments
# are a JSON string that needs a second fromjson.  Tool results come
# as separate role:"tool" messages and are skipped -- the call line
# already carries the useful signal.
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
select(.role == "assistant") |
(.tool_calls // [])[] |
(.function.arguments | fromjson? // {}) as $args |
if   .function.name == "Bash"      then "\(prefix) Shell: " + (($args.command // "") | first_line | truncate(80)) + reset
elif .function.name == "Read"      then "\(prefix) Read "  + ($args.path // $args.file_path // "") + reset
elif .function.name == "Write"     then "\(prefix) Write " + ($args.path // $args.file_path // "") + reset
elif .function.name == "Edit"      then "\(prefix) Edit "  + ($args.path // $args.file_path // "") + reset
elif .function.name == "Glob"      then "\(prefix) Glob "  + ($args.pattern // "") + reset
elif .function.name == "Grep"      then "\(prefix) Grep "  + ($args.pattern // "") + reset
elif .function.name == "WebSearch" then "\(prefix) Search: " + ($args.query // "") + reset
elif .function.name == "FetchURL"  then "\(prefix) Fetch " + ($args.url // "") + reset
elif .function.name == "Agent"     then "\(prefix) Agent: " + (($args.description // $args.prompt // "") | first_line | truncate(60)) + reset
else "\(prefix) " + (.function.name // "unknown") + reset
end
JQ
}

# Detect fatal errors in a Kimi session log.
# stream-json has no terminal error object; failures surface on
# stderr while stdout carries no assistant messages.
agent_detect_fatal() {
    local logfile="$1"

    if [ -f "${logfile}.err" ]; then
        local err_msg
        err_msg=$(grep -i 'error\|invalid.*key\|unauthorized' \
            "${logfile}.err" 2>/dev/null \
            | head -1 || true)
        if [ -n "$err_msg" ] && \
                ! grep -q '"role"[[:space:]]*:[[:space:]]*"assistant"' \
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
    local _rate='429\|rate.limit\|too many requests\|quota\|usage.limit\|hit your.*limit'
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

# Map effort to Kimi's thinking-effort override.
# Args: <effort>
agent_docker_env() {
    local effort="${1:-}"
    if [ -n "$effort" ]; then
        printf -- '-e\nKIMI_MODEL_THINKING_EFFORT=%s\n' "$effort"
    fi
}

# Resolve auth credentials and emit Docker flags.
# Args: <api_key> <auth_token> <auth_mode> <base_url>
# Reads host env: KIMI_API_KEY, KIMI_MODEL_API_KEY, KIMI_CODE_HOME
#
# Auth modes:
#   oauth   — Mount the host Kimi data dir (~/.kimi-code) after
#             `kimi login` on the host.
#   apikey  — Use KIMI_API_KEY via the KIMI_MODEL_* env provider.
#   (empty) — Auto-detect: API key if set, data dir if found.
agent_docker_auth() {
    local api_key="$1" _auth_token="$2" auth_mode="$3" base_url="$4"

    local label=""
    # A host may already export the CLI's own provider variable.
    local key="${api_key:-${KIMI_MODEL_API_KEY:-${KIMI_API_KEY:-}}}"
    local host_home="${KIMI_CODE_HOME:-${HOME}/.kimi-code}"

    # Use --mount instead of -v so Docker errors out (rather than
    # silently creating a directory) if the source path is missing.
    # Read-only: agent_settings copies it to a writable
    # container-local data dir before the first session.
    local _mount_fmt='--mount\ntype=bind,source=%s,target=/home/agent/.kimi-code-host,readonly\n'

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
                printf -- '-e\nKIMI_MODEL_API_KEY=%s\n' "$key"
                label="key"
            fi
            ;;
        *)
            if [ -n "$key" ]; then
                printf -- '-e\nKIMI_MODEL_API_KEY=%s\n' "$key"
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
        printf -- '-e\nKIMI_MODEL_BASE_URL=%s\n' "$base_url"
    fi

    printf -- '-e\nKIMI_DISABLE_TELEMETRY=1\n'
    printf -- '-e\nSWARM_AUTH_MODE=%s\n' "$label"
}

# Dockerfile fragment to install this agent's CLI.
# KIMI_CLI_VERSION is a Docker build-arg; empty = latest.
agent_install_cmd() {
    cat <<'INSTALL'
RUN curl -fsSL https://code.kimi.com/kimi-code/install.sh -o /tmp/kimi-install.sh \
    && KIMI_INSTALL_DIR=/usr/local KIMI_NO_MODIFY_PATH=1 \
       KIMI_VERSION="$KIMI_CLI_VERSION" bash /tmp/kimi-install.sh \
    && rm /tmp/kimi-install.sh
INSTALL
}
