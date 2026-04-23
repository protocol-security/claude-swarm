#!/bin/bash
# Agent driver: Claude Code
# Implements the role interface for Anthropic's Claude Code CLI.

# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

agent_default_model() { echo "claude-opus-4-6"; }
agent_name()    { echo "Claude Code"; }
agent_cmd()     { echo "claude"; }
agent_validate_config() {
    local _model="$1" provider_ref="$2" kind="$3" api_key="$4"
    local oauth_token="$5" bearer_token="$6" auth_file="$7" base_url="$8" _effort="$9"

    case "$kind" in
        anthropic)
            if [ -n "$auth_file" ] || [ -n "$bearer_token" ] || { [ -z "$api_key" ] && [ -z "$oauth_token" ]; }; then
                echo "ERROR: driver claude-code requires provider '${provider_ref}' to supply api_key or oauth_token for kind=anthropic." >&2
                return 1
            fi
            ;;
        anthropic-compatible)
            if [ -z "$base_url" ] || [ -n "$auth_file" ] || [ -n "$oauth_token" ] || { [ -z "$api_key" ] && [ -z "$bearer_token" ]; }; then
                echo "ERROR: driver claude-code requires provider '${provider_ref}' kind=anthropic-compatible with base_url plus api_key or bearer_token." >&2
                return 1
            fi
            ;;
        *)
            echo "ERROR: driver claude-code does not support provider kind '${kind}'." >&2
            return 1
            ;;
    esac
}

agent_version() {
    local v
    v=$(claude --version 2>/dev/null || echo "unknown")
    echo "${v%% *}"
}

# Run one agent session.
# Args: <model> <prompt_text> <logfile> [append_system_prompt_file]
agent_run() {
    local model="$1" prompt_text="$2" logfile="$3"
    local append_file="${4:-}"

    local -a args=(
        --dangerously-skip-permissions
        -p "$prompt_text"
        --model "$model"
        --output-format stream-json
        --verbose
    )
    if [ -n "$append_file" ]; then
        args+=(--append-system-prompt-file "$append_file")
    fi

    # _run_reaped puts claude in its own process group and SIGKILLs
    # the group after the main process exits, so any MCP or helper
    # subprocesses that inherit stdout can't keep the downstream
    # activity-filter pipeline blocked.
    _run_reaped "$logfile" claude "${args[@]}"
}

# Write agent-specific settings files into the workspace.
# Disables Co-Authored-By, attribution header, and telemetry.
# Enables thinking summaries: on Opus 4.7 and later, the API default
# for thinking.display is "omitted" (empty thinking field + encrypted
# signature) for latency reasons.  Setting showThinkingSummaries:true
# opts out of the redact-thinking-2026-02-12 beta header so the
# activity filter has real text to show.  No-op on Opus 4.6 and
# earlier where summaries were already the default.
agent_settings() {
    local workspace="$1"
    mkdir -p "${workspace}/.claude"
    cat > "${workspace}/.claude/settings.local.json" <<'SETTINGS'
{"attribution":{"commit":"","pr":""},"showThinkingSummaries":true,"env":{"CLAUDE_CODE_ATTRIBUTION_HEADER":"0","CLAUDE_CODE_ENABLE_TELEMETRY":"0","CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC":"1"}}
SETTINGS
}

# Extract stats from a session log (JSONL or plain JSON).
# Delegates to the shared JSONL parser in _common.sh.
agent_extract_stats() { _extract_jsonl_stats "$1"; }

# Return the jq program for parsing activity from stream-json.
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
  elif ((.signature // "") | length) > 0 then
    "\(prefix) Think: [encrypted]" + reset
  else
    "\(prefix) Think: [empty]" + reset
  end
elif .type == "tool_use" then
  if   .name == "Bash"  then "\(prefix) Shell: " + ((.input.command // "") | first_line | truncate(80)) + reset
  elif .name == "Read"  then "\(prefix) Read "  + (.input.file_path // .input.path // "") + reset
  elif .name == "Write" then "\(prefix) Write " + (.input.file_path // .input.path // "") + reset
  elif .name == "Edit"  then "\(prefix) Edit "  + (.input.file_path // .input.path // "") + reset
  elif .name == "MultiEdit" then "\(prefix) MultiEdit " + (.input.file_path // .input.path // "") + reset
  elif .name == "Glob"  then "\(prefix) Glob "  + (.input.pattern // "") + reset
  elif .name == "Grep"  then "\(prefix) Grep "  + (.input.pattern // "") + reset
  elif .name == "Task"  then "\(prefix) Task: " + ((.input.description // .input.prompt // "") | first_line | truncate(60)) + reset
  else "\(prefix) " + .name + reset
  end
else empty
end
JQ
}

# Detect fatal errors in a Claude Code session log.
# Returns non-empty string if fatal, empty if OK.
# Args: <logfile> <exit_code>
agent_detect_fatal() {
    local logfile="$1"
    # exit_code=$2 — available but not needed for Claude Code
    # since we detect errors from the structured JSON log.
    local session_error
    session_error=$(grep '"error"[[:space:]]*:' "$logfile" 2>/dev/null \
        | jq -r 'select(.error) | .error' 2>/dev/null | head -1 || true)
    if [ -n "$session_error" ]; then
        # Check zero tokens via result line.
        local result_line tok_in tok_out
        result_line=$(grep '"type"[[:space:]]*:[[:space:]]*"result"' "$logfile" 2>/dev/null | tail -1 || true)
        tok_in=$(echo "$result_line" | jq -r '.usage.input_tokens // 0' 2>/dev/null || echo 0)
        tok_out=$(echo "$result_line" | jq -r '.usage.output_tokens // 0' 2>/dev/null || echo 0)
        if [ "${tok_in:-0}" = "0" ] && [ "${tok_out:-0}" = "0" ]; then
            local session_msg
            session_msg=$(echo "$result_line" | jq -r '.result // empty' 2>/dev/null || true)
            echo "${session_error}: ${session_msg}"
            return
        fi
    fi
}

# Detect retriable errors (rate limits, overload).
# Returns non-empty string if the error is retriable, empty if fatal.
# Args: <logfile> <exit_code>
agent_is_retriable() {
    local logfile="$1"
    grep -q '"overloaded_error"\|"rate_limit_error"\|"rate_limit_event"\|"rate_limit"\|"overloaded"' \
        "$logfile" 2>/dev/null && echo "rate_limited" && return
    grep -q '"Too many requests"\|"rate limit"' \
        "$logfile" 2>/dev/null && echo "rate_limited" && return
    grep -q '"api_error"\|"internal_error"\|"Internal server error"\|"api_error.*500"\|"500.*api_error"' \
        "$logfile" 2>/dev/null && echo "server_error" && return
    if [ -f "${logfile}.err" ]; then
        grep -qi 'rate.limit\|too many requests\|overloaded\|internal.server.error\|api.error.*500\|500.*error' \
            "${logfile}.err" 2>/dev/null && echo "rate_limited" && return
    fi
    return 0
}

# Map generic config to agent-specific Docker env vars.
# Args: <effort>
# Prints -e flags for docker run (one flag per line).
agent_docker_env() {
    local effort="${1:-}"
    if [ -n "$effort" ]; then
        printf -- '-e\nCLAUDE_CODE_EFFORT_LEVEL=%s\n' "$effort"
    fi
}

# Resolve auth credentials and emit Docker -e flags.
# Args: <provider_ref> <kind> <api_key> <oauth_token> <bearer_token> <auth_file> <base_url>
agent_docker_auth() {
    local _provider_ref="$1" kind="$2" api_key="$3" oauth_token="$4"
    local bearer_token="$5" _auth_file="$6" base_url="$7"
    local label=""

    [ -n "$base_url" ] && printf -- '-e\nANTHROPIC_BASE_URL=%s\n' "$base_url"

    case "$kind" in
        anthropic)
            if [ -n "$oauth_token" ]; then
                printf -- '-e\nCLAUDE_CODE_OAUTH_TOKEN=%s\n' "$oauth_token"
                label="oauth"
            elif [ -n "$api_key" ]; then
                printf -- '-e\nANTHROPIC_API_KEY=%s\n' "$api_key"
                label="key"
            fi
            ;;
        anthropic-compatible)
            if [ -n "$bearer_token" ]; then
                printf -- '-e\nANTHROPIC_AUTH_TOKEN=%s\n' "$bearer_token"
                label="token"
            elif [ -n "$api_key" ]; then
                printf -- '-e\nANTHROPIC_API_KEY=%s\n' "$api_key"
                label="key"
            fi
            ;;
    esac

    printf -- '-e\nSWARM_AUTH_MODE=%s\n' "$label"
}

# Dockerfile fragment to install this agent's CLI.
# CLAUDE_CODE_VERSION is a Docker build-arg; empty = latest.
agent_install_cmd() {
    cat <<'INSTALL'
RUN curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh \
    && bash /tmp/claude-install.sh ${CLAUDE_CODE_VERSION:+$CLAUDE_CODE_VERSION} \
    && rm /tmp/claude-install.sh
ENV PATH="/home/agent/.local/bin:${PATH}"
INSTALL
}
