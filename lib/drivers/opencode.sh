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
# Args: <model> <provider_ref> <kind> <api_key> <oauth_token> <bearer_token> <auth_file> <base_url> <effort>
agent_validate_config() {
    local model="$1" provider_ref="$2" kind="$3" api_key="$4"
    local oauth_token="$5" bearer_token="$6" auth_file="$7" base_url="$8" _effort="$9"
    local auth_count=0 model_prefix=""

    if [[ "$model" != */* ]]; then
        echo "ERROR: driver opencode requires model in provider/model format (for example anthropic/claude-sonnet-4-5-20250929)." >&2
        return 1
    fi
    model_prefix="${model%%/*}"
    [ -n "$api_key" ] && auth_count=$((auth_count + 1))
    [ -n "$oauth_token" ] && auth_count=$((auth_count + 1))
    [ -n "$bearer_token" ] && auth_count=$((auth_count + 1))
    [ -n "$auth_file" ] && auth_count=$((auth_count + 1))

    case "$kind" in
        anthropic)
            if [ "$model_prefix" != "anthropic" ] || [ "$auth_count" -ne 1 ] || [ -n "$bearer_token" ]; then
                echo "ERROR: driver opencode requires kind=anthropic, model prefix anthropic/, and exactly one of api_key, oauth_token, or auth_file." >&2
                return 1
            fi
            ;;
        anthropic-compatible)
            if [ "$model_prefix" != "anthropic" ] || [ -z "$base_url" ] || [ "$auth_count" -ne 1 ] || [ -n "$oauth_token" ]; then
                echo "ERROR: driver opencode requires kind=anthropic-compatible, model prefix anthropic/, base_url, and exactly one of api_key, bearer_token, or auth_file." >&2
                return 1
            fi
            ;;
        openai)
            if [ "$model_prefix" != "openai" ] || [ "$auth_count" -ne 1 ] || [ -n "$oauth_token" ] || [ -n "$bearer_token" ]; then
                echo "ERROR: driver opencode requires kind=openai, model prefix openai/, and exactly one of api_key or auth_file." >&2
                return 1
            fi
            ;;
        openai-compatible)
            if [ "$model_prefix" != "$provider_ref" ] || [ -z "$base_url" ] || [ "$auth_count" -ne 1 ] || [ -n "$oauth_token" ]; then
                echo "ERROR: driver opencode requires kind=openai-compatible, model prefix ${provider_ref}/, base_url, and exactly one of api_key, bearer_token, or auth_file." >&2
                return 1
            fi
            ;;
        gemini)
            if [ "$model_prefix" != "google" ] || [ -z "$api_key" ] || [ "$auth_count" -ne 1 ] || [ -n "$base_url" ]; then
                echo "ERROR: driver opencode requires kind=gemini, model prefix google/, and api_key only." >&2
                return 1
            fi
            ;;
        kimi)
            if [ "$model_prefix" != "moonshotai" ] || [ -z "$api_key" ] || [ "$auth_count" -ne 1 ]; then
                echo "ERROR: driver opencode requires kind=kimi, model prefix moonshotai/, and api_key." >&2
                return 1
            fi
            ;;
        *)
            echo "ERROR: driver opencode does not support provider kind '${kind}'." >&2
            return 1
            ;;
    esac
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
    local config_dir="${HOME}/.config/opencode"
    local data_dir="${HOME}/.local/share/opencode"
    local config_file="${config_dir}/opencode.json"
    local auth_file="${data_dir}/auth.json"
    local provider_ref="${SWARM_PROVIDER_NAME:-}"
    local kind="${SWARM_PROVIDER_KIND:-}"
    local model="${SWARM_MODEL:-}"
    local api_key="${SWARM_PROVIDER_API_KEY:-}"
    local oauth_token="${SWARM_PROVIDER_OAUTH_TOKEN:-}"
    local bearer_token="${SWARM_PROVIDER_BEARER_TOKEN:-}"
    local base_url="${SWARM_PROVIDER_BASE_URL:-}"
    local mounted_auth="${SWARM_PROVIDER_AUTH_FILE_CONTAINER:-}"
    local model_suffix="${model#*/}"
    local config=""

    mkdir -p "$config_dir" "$data_dir"
    rm -f "$auth_file"
    if [ -n "$mounted_auth" ] && [ -f "$mounted_auth" ]; then
        cp "$mounted_auth" "$auth_file"
    elif [ "$kind" = "anthropic" ] && [ -n "$oauth_token" ]; then
        jq -nc --arg access "$oauth_token" '
            {anthropic:{type:"oauth",refresh:"",access:$access,expires:253402300799000}}
        ' > "$auth_file"
    fi

    case "$kind" in
        anthropic|anthropic-compatible)
            config=$(jq -nc \
                --arg model "$model" \
                --arg base_url "$base_url" \
                --arg api_key "$api_key" \
                --arg bearer_token "$bearer_token" '
                {
                  "$schema": "https://opencode.ai/config.json",
                  autoupdate: false,
                  model: $model,
                  provider: {
                    anthropic: {
                      options:
                        ((if $base_url != "" then {baseURL: $base_url} else {} end) +
                         (if $api_key != "" then {apiKey: $api_key} else {} end) +
                         (if $bearer_token != "" then {headers: {Authorization: ("Bearer " + $bearer_token)}} else {} end))
                    }
                  }
                }')
            ;;
        openai)
            config=$(jq -nc \
                --arg model "$model" \
                --arg base_url "$base_url" \
                --arg api_key "$api_key" '
                {
                  "$schema": "https://opencode.ai/config.json",
                  autoupdate: false,
                  model: $model,
                  provider: {
                    openai: {
                      options:
                        ((if $base_url != "" then {baseURL: $base_url} else {} end) +
                         (if $api_key != "" then {apiKey: $api_key} else {} end))
                    }
                  }
                }')
            ;;
        openai-compatible)
            config=$(jq -nc \
                --arg provider_ref "$provider_ref" \
                --arg model "$model" \
                --arg model_suffix "$model_suffix" \
                --arg base_url "$base_url" \
                --arg api_key "$api_key" \
                --arg bearer_token "$bearer_token" '
                {
                  "$schema": "https://opencode.ai/config.json",
                  autoupdate: false,
                  model: $model,
                  provider: {
                    ($provider_ref): {
                      npm: "@ai-sdk/openai-compatible",
                      name: $provider_ref,
                      options:
                        ((if $base_url != "" then {baseURL: $base_url} else {} end) +
                         (if $api_key != "" then {apiKey: $api_key} else {} end) +
                         (if $bearer_token != "" then {headers: {Authorization: ("Bearer " + $bearer_token)}} else {} end)),
                      models: {
                        ($model_suffix): {}
                      }
                    }
                  }
                }')
            ;;
        gemini)
            config=$(jq -nc \
                --arg model "$model" \
                --arg api_key "$api_key" '
                {
                  "$schema": "https://opencode.ai/config.json",
                  autoupdate: false,
                  model: $model,
                  provider: {
                    google: {
                      options: {
                        apiKey: $api_key
                      }
                    }
                  }
                }')
            ;;
        kimi)
            config=$(jq -nc \
                --arg model "$model" \
                --arg api_key "$api_key" \
                --arg base_url "$base_url" '
                {
                  "$schema": "https://opencode.ai/config.json",
                  autoupdate: false,
                  model: $model,
                  provider: {
                    moonshotai: {
                      options:
                        ({apiKey: $api_key} +
                         (if $base_url != "" then {baseURL: $base_url} else {} end))
                    }
                  }
                }')
            ;;
        *)
            config=$(jq -nc --arg model "$model" '
                {"$schema":"https://opencode.ai/config.json",autoupdate:false,model:$model}
            ')
            ;;
    esac

    printf '%s\n' "$config" > "$config_file"
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
    local _provider_ref="$1" _kind="$2" api_key="$3" oauth_token="$4"
    local bearer_token="$5" auth_file="$6" _base_url="$7"
    local label=""
    local _mount_fmt='--mount\ntype=bind,source=%s,target=/tmp/swarm/opencode-provider-auth.json,readonly\n'

    if [ -f "$auth_file" ]; then
        printf -- "$_mount_fmt" "$auth_file"
        printf -- '-e\nSWARM_PROVIDER_AUTH_FILE_CONTAINER=/tmp/swarm/opencode-provider-auth.json\n'
        label="file"
    elif [ -n "$oauth_token" ]; then
        label="oauth"
    elif [ -n "$bearer_token" ]; then
        label="token"
    elif [ -n "$api_key" ]; then
        label="key"
    fi

    printf -- '-e\nSWARM_AUTH_MODE=%s\n' "$label"
}

agent_install_cmd() {
    cat <<'INSTALL'
RUN npm install -g opencode-ai
INSTALL
}
