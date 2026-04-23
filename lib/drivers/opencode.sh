#!/bin/bash
# shellcheck disable=SC2034
# Agent driver: OpenCode
# Implements the role interface for OpenCode's headless CLI.

# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

agent_default_model() { echo "anthropic/claude-sonnet-4-5-20250929"; }
agent_name()    { echo "OpenCode"; }
agent_cmd()     { echo "opencode"; }

# Validate launch-time config for the OpenCode driver.
# Args: <model> <base_url> <api_key> <effort> <auth_mode> <auth_token>
agent_validate_config() {
    local model="$1" base_url="$2" api_key="$3" _effort="$4"
    local auth_mode="$5" auth_token="$6"

    if [ -n "$base_url" ] || [ -n "$api_key" ] || [ -n "$auth_mode" ] || [ -n "$auth_token" ]; then
        echo "ERROR: driver opencode does not use swarm auth/base_url fields; configure native credentials via OPENCODE_AUTH_JSON or ~/.local/share/opencode/auth.json." >&2
        return 1
    fi
    if [[ "$model" != */* ]]; then
        echo "ERROR: driver opencode requires model in provider/model format (for example anthropic/claude-sonnet-4-5-20250929)." >&2
        return 1
    fi
}

agent_version() {
    local v
    v=$(opencode --version 2>/dev/null || echo "unknown")
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

    local variant_args=()
    if [ -n "${SWARM_EFFORT:-}" ]; then
        variant_args=(--variant "${SWARM_EFFORT}")
    fi

    _run_reaped "$logfile" opencode run \
        --format json \
        --dir /workspace \
        -m "$model" \
        "${variant_args[@]+"${variant_args[@]}"}" \
        "$prompt_text"
}

agent_settings() {
    local _workspace="$1"
    mkdir -p "${HOME}/.config/opencode" "${HOME}/.local/share/opencode"
}

agent_extract_stats() {
    local logfile="$1"
    local stats
    stats=$(jq -Rsc '
        [split("\n")[] | select(length > 0) | fromjson?] as $events |
        {
          turns: ([$events[] | select((.role // "") == "assistant" or ((.type // "") == "message" and (.role // "") == "assistant"))] | length),
          dur: (([$events[] | (.duration_ms // .durationMs // empty)] | last) // 0),
          tok_in: (([$events[] | (.usage.input_tokens // .usage.inputTokens // empty)] | last) // 0),
          tok_out: (([$events[] | (.usage.output_tokens // .usage.outputTokens // empty)] | last) // 0),
          cache_rd: (([$events[] | (.usage.cache_read_input_tokens // .usage.cached_input_tokens // empty)] | last) // 0)
        }' "$logfile" 2>/dev/null || true)
    if [ -z "$stats" ] || [ "$stats" = "null" ]; then
        printf "0\t0\t0\t0\t0\t0\t0\t0"
        return
    fi
    local turns dur tok_in tok_out cache_rd
    turns=$(echo "$stats" | jq -r '.turns // 0')
    dur=$(echo "$stats" | jq -r '.dur // 0')
    tok_in=$(echo "$stats" | jq -r '.tok_in // 0')
    tok_out=$(echo "$stats" | jq -r '.tok_out // 0')
    cache_rd=$(echo "$stats" | jq -r '.cache_rd // 0')
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s" \
        "0" "$tok_in" "$tok_out" "$cache_rd" "0" "$dur" "$dur" "$turns"
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

def normalize_args:
  if type == "string" then (fromjson? // {}) else (. // {}) end;

def render_tool($name; $args):
  if   $name == "bash"     then "\(prefix) Shell: " + (($args.command // "") | first_line | truncate(80)) + reset
  elif $name == "read"     then "\(prefix) Read "  + ($args.filePath // $args.file_path // $args.path // "") + reset
  elif $name == "write"    then "\(prefix) Write " + ($args.filePath // $args.file_path // $args.path // "") + reset
  elif $name == "edit"     then "\(prefix) Edit "  + ($args.filePath // $args.file_path // $args.path // "") + reset
  elif $name == "glob"     then "\(prefix) Glob "  + ($args.pattern // "") + reset
  elif $name == "grep"     then "\(prefix) Grep "  + ($args.pattern // "") + reset
  elif $name == "webfetch" then "\(prefix) Fetch " + ($args.url // "") + reset
  elif $name == "websearch" then "\(prefix) Search: " + (($args.query // "") | first_line | truncate(80)) + reset
  else empty end;

fromjson? // empty as $event |
if ($event.type // "") == "tool_call" then
  render_tool(($event.toolName // $event.tool_name // $event.name // ""); (($event.parameters // $event.params // {}) | normalize_args))
elif ($event.type // "") == "tool_call_update" then
  ($event.toolCall // $event.tool_call // {}) as $tc |
  render_tool(($tc.toolName // $tc.tool_name // $tc.name // ""); (($tc.parameters // $tc.params // {}) | normalize_args))
elif ($event.role // "") == "assistant" then
  ($event.tool_calls // [])[]? as $tc |
  render_tool(($tc.function.name // ""); (($tc.function.arguments // {}) | normalize_args))
else empty end
JQ
}

agent_detect_fatal() {
    local logfile="$1" exit_code="${2:-0}"
    [ "$exit_code" -eq 0 ] && return 0

    local err_msg=""
    if [ -f "${logfile}.err" ]; then
        err_msg=$(sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' "${logfile}.err" \
            | grep -i 'error\|failed\|invalid\|unauthorized\|readonly database\|permission' \
            | head -1 || true)
    fi
    if [ -z "$err_msg" ]; then
        err_msg=$(sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' "$logfile" 2>/dev/null \
            | grep -i 'error\|failed\|invalid\|unauthorized\|readonly database\|permission' \
            | head -1 || true)
    fi
    if [ -n "$err_msg" ]; then
        echo "$err_msg"
    else
        echo "opencode exited with code ${exit_code}"
    fi
}

agent_is_retriable() {
    local logfile="$1"
    local _pattern='429\|rate.limit\|too many requests\|timeout\|timed out\|econnreset\|enotfound\|unable to connect\|temporarily unavailable\|5[0-9][0-9]'
    grep -qi "$_pattern" "$logfile" 2>/dev/null && echo "transient_error" && return
    if [ -f "${logfile}.err" ]; then
        grep -qi "$_pattern" "${logfile}.err" 2>/dev/null && echo "transient_error" && return
    fi
    return 0
}

agent_docker_env() {
    local _effort="${1:-}"
    printf -- '-e\nOPENCODE_DISABLE_AUTOUPDATE=1\n'
}

agent_docker_auth() {
    local _api_key="$1" _auth_token="$2" _auth_mode="$3" _base_url="$4"
    local auth_json="${OPENCODE_AUTH_JSON:-${HOME}/.local/share/opencode/auth.json}"
    local label=""
    local _mount_fmt='--mount\ntype=bind,source=%s,target=/home/agent/.local/share/opencode/auth.json,readonly\n'

    if [ -d "$auth_json" ]; then
        echo "WARNING: ${auth_json} is a directory (should be a file)." >&2
    elif [ -f "$auth_json" ]; then
        printf -- "$_mount_fmt" "$auth_json"
        label="file"
    fi

    printf -- '-e\nSWARM_AUTH_MODE=%s\n' "$label"
}

agent_install_cmd() {
    cat <<'INSTALL'
RUN npm install -g opencode-ai
INSTALL
}
