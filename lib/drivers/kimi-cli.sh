#!/bin/bash
# shellcheck disable=SC2034
# Agent driver: Kimi Code CLI
# Implements the role interface for Moonshot's Kimi CLI.

# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

agent_default_model() { echo "kimi-for-coding"; }
agent_name()    { echo "Kimi CLI"; }
agent_cmd()     { echo "kimi"; }

# Validate launch-time config for the Kimi driver.
# Args: <model> <provider_ref> <kind> <api_key> <oauth_token> <bearer_token> <auth_file> <base_url> <effort>
agent_validate_config() {
    local _model="$1" provider_ref="$2" kind="$3" api_key="$4"
    local oauth_token="$5" bearer_token="$6" auth_file="$7" _base_url="$8" _effort="$9"

    if [ "$kind" != "kimi" ] || [ -z "$api_key" ] || [ -n "$oauth_token" ] \
        || [ -n "$bearer_token" ] || [ -n "$auth_file" ]; then
        echo "ERROR: driver kimi-cli requires provider '${provider_ref}' kind=kimi with api_key only." >&2
        return 1
    fi
}

agent_version() {
    local v
    v=$(kimi --version 2>/dev/null || echo "unknown")
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

    local base_url="${SWARM_KIMI_BASE_URL:-https://api.kimi.com/coding/v1}"
    local api_key="${SWARM_KIMI_API_KEY:-}"
    local cfg
    cfg=$(jq -nc \
        --arg model "$model" \
        --arg base_url "$base_url" \
        --arg api_key "$api_key" '
        {
          default_model: $model,
          providers: {
            swarm: {
              type: "kimi",
              base_url: $base_url,
              api_key: $api_key
            }
          },
          models: {
            ($model): {
              provider: "swarm",
              model: $model,
              max_context_size: 262144
            }
          }
        }')

    local thinking_args=()
    case "${SWARM_EFFORT:-}" in
        "" ) ;;
        none|off) thinking_args=(--no-thinking) ;;
        *)        thinking_args=(--thinking) ;;
    esac

    _run_reaped "$logfile" kimi \
        --print \
        --work-dir /workspace \
        --config "$cfg" \
        --model "$model" \
        --output-format stream-json \
        "${thinking_args[@]+"${thinking_args[@]}"}" \
        -p "$prompt_text"
}

agent_settings() {
    local workspace="$1"
    mkdir -p "${HOME}/.kimi"
    _bridge_agents_md "$workspace"
}

agent_extract_stats() {
    local logfile="$1"
    local stats
    stats=$(jq -Rsc '
        [split("\n")[] | select(length > 0) | fromjson?] as $events |
        {
          turns: ([$events[] | select(.role == "assistant")] | length)
        }' "$logfile" 2>/dev/null || true)
    if [ -z "$stats" ] || [ "$stats" = "null" ]; then
        printf "0\t0\t0\t0\t0\t0\t0\t0"
        return
    fi
    local turns
    turns=$(echo "$stats" | jq -r '.turns // 0')
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s" \
        "0" "0" "0" "0" "0" "0" "0" "$turns"
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

def tool_args:
  (.function.arguments | fromjson? // {});

fromjson? // empty |
if (.role // "") == "assistant" then
  .tool_calls[]? as $tc |
  ($tc.function.name // "") as $name |
  ($tc | tool_args) as $args |
  if   $name == "Shell"          then "\(prefix) Shell: " + (($args.command // "") | first_line | truncate(80)) + reset
  elif $name == "ReadFile"       then "\(prefix) Read "  + ($args.file_path // $args.path // "") + reset
  elif $name == "WriteFile"      then "\(prefix) Write " + ($args.file_path // $args.path // "") + reset
  elif $name == "StrReplaceFile" then "\(prefix) Edit "  + ($args.file_path // $args.path // "") + reset
  elif $name == "Glob"           then "\(prefix) Glob "  + ($args.pattern // "") + reset
  elif $name == "Grep"           then "\(prefix) Grep "  + ($args.pattern // "") + reset
  elif $name == "SearchWeb"      then "\(prefix) Search: " + (($args.query // "") | first_line | truncate(80)) + reset
  elif $name == "FetchURL"       then "\(prefix) Fetch " + ($args.url // "") + reset
  elif $name == "Task"           then "\(prefix) Task: " + (($args.description // $args.prompt // "") | first_line | truncate(60)) + reset
  elif $name == "SetTodoList"    then "\(prefix) Todo" + reset
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
            | grep -i 'error\|invalid\|quota\|limit\|unauthorized\|forbidden\|failed' \
            | head -1 || true)
        if [ -z "$err_msg" ]; then
            err_msg=$(sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' "${logfile}.err" \
                | sed '/^[[:space:]]*$/d' \
                | head -1 || true)
        fi
    fi
    if [ -z "$err_msg" ]; then
        err_msg=$(sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' "$logfile" 2>/dev/null \
            | grep -vi '^{".*}$' \
            | grep -i 'error\|invalid\|quota\|limit\|unauthorized\|forbidden\|failed' \
            | head -1 || true)
    fi
    if [ -z "$err_msg" ]; then
        err_msg=$(sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' "$logfile" 2>/dev/null \
            | grep -vi '^{".*}$' \
            | sed '/^[[:space:]]*$/d' \
            | head -1 || true)
    fi
    if [ -n "$err_msg" ]; then
        echo "$err_msg"
    elif [ "$exit_code" -ne 75 ]; then
        echo "kimi exited with code ${exit_code}"
    fi
}

agent_is_retriable() {
    local logfile="$1" exit_code="${2:-0}"
    [ "$exit_code" = "75" ] && echo "transient_error" && return

    local _pattern='429\|rate.limit\|too many requests\|timeout\|timed out\|5[0-9][0-9]\|connection reset\|temporarily unavailable'
    grep -qi "$_pattern" "$logfile" 2>/dev/null && echo "transient_error" && return
    if [ -f "${logfile}.err" ]; then
        grep -qi "$_pattern" "${logfile}.err" 2>/dev/null && echo "transient_error" && return
    fi
    return 0
}

agent_docker_env() {
    local _effort="${1:-}"
    printf -- '-e\nKIMI_CLI_NO_AUTO_UPDATE=1\n'
}

agent_docker_auth() {
    local _provider_ref="$1" _kind="$2" api_key="$3" _oauth_token="$4"
    local _bearer_token="$5" _auth_file="$6" base_url="$7"

    local label=""
    local resolved_base="${base_url:-https://api.kimi.com/coding/v1}"

    if [ -n "$api_key" ]; then
        printf -- '-e\nSWARM_KIMI_API_KEY=%s\n' "$api_key"
        label="key"
    fi
    printf -- '-e\nSWARM_KIMI_BASE_URL=%s\n' "$resolved_base"
    printf -- '-e\nSWARM_AUTH_MODE=%s\n' "$label"
}

agent_install_cmd() {
    cat <<'INSTALL'
RUN curl -LsSf https://code.kimi.com/install.sh | bash
INSTALL
}
