#!/bin/bash
# shellcheck disable=SC2034
# Agent driver: Factory Droid
# Implements the role interface for Factory's droid CLI.

# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

agent_default_model() { echo "glm-4.7"; }
agent_name()    { echo "Droid"; }
agent_cmd()     { echo "droid"; }

# Validate launch-time config for the Droid driver.
# Args: <model> <base_url> <api_key> <effort> <auth_mode> <auth_token>
agent_validate_config() {
    local _model="$1" base_url="$2" api_key="$3" _effort="$4"
    local auth_mode="$5" auth_token="$6"

    if [ -n "$base_url" ] || [ -n "$api_key" ] || [ -n "$auth_mode" ] || [ -n "$auth_token" ]; then
        echo "ERROR: driver droid does not use swarm auth/base_url fields; configure FACTORY_API_KEY in the environment." >&2
        return 1
    fi
    if [ -z "${FACTORY_API_KEY:-}" ]; then
        echo "ERROR: driver droid requires FACTORY_API_KEY in the environment." >&2
        return 1
    fi
}

agent_version() {
    local v
    v=$(droid --version 2>/dev/null || echo "unknown")
    echo "$v" | grep -oE '[0-9]+(\.[0-9]+)+' | head -1 || echo "unknown"
}

# Run one agent session.
# Args: <model> <prompt_text> <logfile> [append_system_prompt_file]
agent_run() {
    local model="$1" prompt_text="$2" logfile="$3"
    local append_file="${4:-}"

    if [ -n "$append_file" ] && [ -f "$append_file" ]; then
        prompt_text="$(cat "$append_file")"$'\n\n'"$prompt_text"
    fi

    local effort_args=()
    if [ -n "${SWARM_EFFORT:-}" ]; then
        effort_args=(-r "${SWARM_EFFORT}")
    fi

    _run_reaped "$logfile" droid exec \
        --skip-permissions-unsafe \
        --cwd /workspace \
        --output-format stream-json \
        -m "$model" \
        "${effort_args[@]+"${effort_args[@]}"}" \
        "$prompt_text"
}

agent_settings() {
    local workspace="$1"
    local factory_home="${HOME}/.factory"
    mkdir -p "$factory_home"
    _bridge_agents_md "$workspace"

    if [ -n "${SWARM_EFFORT:-}" ]; then
        cat > "${factory_home}/settings.local.json" <<SETTINGS
{"reasoningEffort":"${SWARM_EFFORT}"}
SETTINGS
    fi
}

agent_extract_stats() {
    local logfile="$1"
    local RESULT_LINE
    RESULT_LINE=$(grep '"type"[[:space:]]*:[[:space:]]*"completion"' "$logfile" 2>/dev/null | tail -1 || true)
    if [ -z "$RESULT_LINE" ]; then
        printf "0\t0\t0\t0\t0\t0\t0\t0"
        return
    fi
    local dur turns
    dur=$(echo "$RESULT_LINE" | jq -r '.durationMs // .duration_ms // 0' 2>/dev/null || true)
    dur="${dur:-0}"
    turns=$(echo "$RESULT_LINE" | jq -r '.numTurns // .num_turns // 0' 2>/dev/null || true)
    turns="${turns:-0}"
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s" \
        "0" "0" "0" "0" "0" "$dur" "$dur" "$turns"
}

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
if (.type // "") == "tool_call" then
  if   .toolName == "Execute" then "\(prefix) Shell: " + ((.parameters.command // "") | first_line | truncate(80)) + reset
  elif .toolName == "Read"    then "\(prefix) Read "  + (.parameters.file_path // .parameters.path // "") + reset
  elif .toolName == "Write"   then "\(prefix) Write " + (.parameters.file_path // .parameters.path // "") + reset
  elif .toolName == "Edit"    then "\(prefix) Edit "  + (.parameters.file_path // .parameters.path // "") + reset
  elif .toolName == "Glob"    then "\(prefix) Glob "  + (.parameters.pattern // "") + reset
  elif .toolName == "Grep"    then "\(prefix) Grep "  + (.parameters.pattern // "") + reset
  elif .toolName == "Task"    then "\(prefix) Task: " + ((.parameters.description // .parameters.prompt // "") | first_line | truncate(60)) + reset
  else empty end
else empty end
JQ
}

agent_detect_fatal() {
    local logfile="$1" exit_code="${2:-0}"
    [ "$exit_code" -eq 0 ] && return 0

    local err_msg=""
    if [ -f "${logfile}.err" ]; then
        err_msg=$(sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' "${logfile}.err" \
            | grep -i 'error\|failed\|permission\|api key\|unauthorized\|forbidden' \
            | head -1 || true)
    fi
    if [ -z "$err_msg" ]; then
        err_msg=$(grep '"type"[[:space:]]*:[[:space:]]*"error"' "$logfile" 2>/dev/null \
            | jq -r '.message // .error // "unknown error"' 2>/dev/null \
            | head -1 || true)
    fi
    if [ -z "$err_msg" ] && [ -f "$logfile" ]; then
        err_msg=$(sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' "$logfile" \
            | grep -vi '^{".*}$' \
            | grep -i 'error\|failed\|permission\|api key\|unauthorized\|forbidden' \
            | head -1 || true)
    fi
    if [ -n "$err_msg" ]; then
        echo "$err_msg"
    else
        echo "droid exited with code ${exit_code}"
    fi
}

agent_is_retriable() {
    local logfile="$1"
    local _pattern='429\|rate limit\|too many requests\|timeout\|timed out\|econnreset\|enotfound\|temporarily unavailable\|5[0-9][0-9]'
    grep -qi "$_pattern" "$logfile" 2>/dev/null && echo "transient_error" && return
    if [ -f "${logfile}.err" ]; then
        grep -qi "$_pattern" "${logfile}.err" 2>/dev/null && echo "transient_error" && return
    fi
    return 0
}

agent_docker_env() { :; }

agent_docker_auth() {
    local _api_key="$1" _auth_token="$2" _auth_mode="$3" _base_url="$4"
    local label=""

    if [ -n "${FACTORY_API_KEY:-}" ]; then
        printf -- '-e\nFACTORY_API_KEY=%s\n' "${FACTORY_API_KEY}"
        label="key"
    fi
    printf -- '-e\nSWARM_AUTH_MODE=%s\n' "$label"
}

agent_install_cmd() {
    cat <<'INSTALL'
RUN npm install -g droid
INSTALL
}
