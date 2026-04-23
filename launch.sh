#!/bin/bash
set -euo pipefail

# Create bare repos, build image, launch N agent containers.
# Usage: ./launch.sh {start|stop|logs N|status|wait|post-process}

SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<HELP
Usage: $0 [COMMAND] [OPTIONS]

Orchestrate coding agents in Docker containers.
Default command is 'start' when none is specified.

Commands:
  start [OPTIONS]      Build image, create bare repo, launch agents.
  stop                 Stop all running agent containers.
  logs N               Tail logs for agent N (default: 1).
  status               Show running/stopped state for each agent.
  wait                 Block until all agents exit, then harvest
                       (runs post-process first if configured).
  post-process         Run the post-processing agent from the config.

Start options:
  --dashboard          Open the TUI dashboard after launch.

Environment:
  SWARM_CONFIG              Path to swarmfile (or place swarm.json in repo root).
  SWARM_TITLE               Dashboard title override.
  SWARM_SKIP_DEP_CHECK      Set to 1 to silence version warnings.
HELP
    exit 0
fi

source "$SWARM_DIR/lib/check-deps.sh"
check_deps git jq docker

REPO_ROOT="$(git rev-parse --show-toplevel)"
PROJECT="$(basename "$REPO_ROOT")"
SWARM_RUN_HASH="$(git -C "$REPO_ROOT" rev-parse --short=7 HEAD 2>/dev/null || echo "unknown")"
SWARM_RUN_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
SWARM_RUN_CONTEXT="${PROJECT}@${SWARM_RUN_HASH} (${SWARM_RUN_BRANCH})"
BARE_REPO="/tmp/${PROJECT}-upstream.git"
IMAGE_NAME="${PROJECT}-agent"

_launch_driver_fns=(agent_default_model agent_docker_env agent_docker_auth agent_validate_config)

unload_launch_driver() {
    local _fn
    for _fn in "${_launch_driver_fns[@]}"; do
        unset -f "$_fn" 2>/dev/null || true
    done
}

load_launch_driver() {
    local driver="$1"
    local file="${SWARM_DIR}/lib/drivers/${driver}.sh"
    local _fn

    unload_launch_driver
    # shellcheck source=lib/drivers/claude-code.sh
    source "$file"
    for _fn in "${_launch_driver_fns[@]}"; do
        if ! type -t "$_fn" >/dev/null 2>&1; then
            echo "ERROR: driver '${driver}' missing required launch function: ${_fn}" >&2
            exit 1
        fi
    done
}

# Expand a single $VAR reference from the host environment.
# Supports "$VAR" (entire value is a reference) only -- not inline
# interpolation.  Returns the original string if no match.
expand_env_ref() {
    local val="$1"
    if [[ "$val" =~ ^\$([A-Za-z_][A-Za-z_0-9]*)$ ]]; then
        local varname="${BASH_REMATCH[1]}"
        printf '%s' "${!varname:-}"
    else
        printf '%s' "$val"
    fi
}

expand_path_ref() {
    local val
    val="$(expand_env_ref "$1")"
    printf '%s' "${val/#\~/$HOME}"
}

has_legacy_auth_fields() {
    jq -e '
        def legacy:
            has("auth") or has("api_key") or has("auth_token") or has("base_url");
        ([.agents[]? | legacy] | any) or ((.post_process? // {}) | legacy)
    ' "$1" >/dev/null 2>&1
}

resolve_provider_ref() {
    local config_file="$1" provider_ref="$2"
    jq -r --arg ref "$provider_ref" '
        .providers[$ref] // empty |
        [(.kind // ""),
         (.api_key // ""),
         (.oauth_token // ""),
         (.bearer_token // ""),
         (.auth_file // ""),
         (.base_url // "")] | join("|")
    ' "$config_file" 2>/dev/null
}

validate_provider_shape() {
    local provider_ref="$1" kind="$2" api_key="$3" oauth_token="$4"
    local bearer_token="$5" auth_file="$6" base_url="$7"
    local auth_count=0

    [ -n "$api_key" ] && auth_count=$((auth_count + 1))
    [ -n "$oauth_token" ] && auth_count=$((auth_count + 1))
    [ -n "$bearer_token" ] && auth_count=$((auth_count + 1))
    [ -n "$auth_file" ] && auth_count=$((auth_count + 1))

    if [ -z "$kind" ]; then
        echo "ERROR: provider '${provider_ref}' is missing required field: kind." >&2
        return 1
    fi

    case "$kind" in
        none)
            if [ "$auth_count" -ne 0 ] || [ -n "$base_url" ]; then
                echo "ERROR: provider '${provider_ref}' kind=none does not accept auth or base_url fields." >&2
                return 1
            fi
            ;;
        anthropic)
            if [ "$auth_count" -ne 1 ]; then
                echo "ERROR: provider '${provider_ref}' kind=anthropic requires exactly one of api_key, oauth_token, or auth_file." >&2
                return 1
            fi
            [ -n "$bearer_token" ] && {
                echo "ERROR: provider '${provider_ref}' kind=anthropic does not accept bearer_token." >&2
                return 1
            }
            ;;
        anthropic-compatible)
            if [ -z "$base_url" ]; then
                echo "ERROR: provider '${provider_ref}' kind=anthropic-compatible requires base_url." >&2
                return 1
            fi
            if [ "$auth_count" -ne 1 ] || [ -n "$oauth_token" ]; then
                echo "ERROR: provider '${provider_ref}' kind=anthropic-compatible requires exactly one of api_key, bearer_token, or auth_file." >&2
                return 1
            fi
            ;;
        openai)
            if [ "$auth_count" -ne 1 ] || [ -n "$oauth_token" ] || [ -n "$bearer_token" ]; then
                echo "ERROR: provider '${provider_ref}' kind=openai requires exactly one of api_key or auth_file." >&2
                return 1
            fi
            ;;
        openai-compatible)
            if [ -z "$base_url" ]; then
                echo "ERROR: provider '${provider_ref}' kind=openai-compatible requires base_url." >&2
                return 1
            fi
            if [ "$auth_count" -ne 1 ] || [ -n "$oauth_token" ]; then
                echo "ERROR: provider '${provider_ref}' kind=openai-compatible requires exactly one of api_key, bearer_token, or auth_file." >&2
                return 1
            fi
            ;;
        gemini|kimi|factory)
            if [ "$auth_count" -ne 1 ] || [ -z "$api_key" ] || [ -n "$oauth_token" ] || [ -n "$bearer_token" ] || [ -n "$auth_file" ]; then
                echo "ERROR: provider '${provider_ref}' kind=${kind} requires api_key and does not accept oauth_token, bearer_token, or auth_file." >&2
                return 1
            fi
            if [ "$kind" != "kimi" ] && [ -n "$base_url" ]; then
                echo "ERROR: provider '${provider_ref}' kind=${kind} does not accept base_url." >&2
                return 1
            fi
            ;;
        *)
            echo "ERROR: provider '${provider_ref}' has unknown kind '${kind}'." >&2
            return 1
            ;;
    esac

    if [ -n "$auth_file" ] && [ ! -f "$auth_file" ]; then
        echo "ERROR: provider '${provider_ref}' auth_file not found: ${auth_file}" >&2
        return 1
    fi
}

# Docker containers may create files owned by a different UID inside
# bind-mounted host directories.  Plain rm -rf fails without root.
# Use a throwaway Alpine container (Docker is already required) so
# we never need sudo/su -c.
rm_docker_dir() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    local parent base
    parent="$(dirname "$dir")"
    base="$(basename "$dir")"
    docker run --rm -v "${parent}:${parent}" alpine \
        rm -rf "${parent}/${base}" 2>/dev/null \
        || rm -rf "$dir" 2>/dev/null || true
}

CONFIG_FILE="${SWARM_CONFIG:-}"
if [ -z "$CONFIG_FILE" ] && [ -f "$REPO_ROOT/swarm.json" ]; then
    CONFIG_FILE="$REPO_ROOT/swarm.json"
fi

if [ -z "$CONFIG_FILE" ]; then
    echo "ERROR: No swarmfile found.  Create swarm.json in your repo root or set SWARM_CONFIG." >&2
    exit 1
fi
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Swarmfile ${CONFIG_FILE} not found." >&2
    exit 1
fi

if has_legacy_auth_fields "$CONFIG_FILE"; then
    echo "ERROR: legacy auth fields auth/api_key/auth_token/base_url are no longer supported." >&2
    echo "       Define providers under top-level \"providers\" and reference them with \"provider\"." >&2
    exit 1
fi

if ! jq -e '.providers | type == "object"' "$CONFIG_FILE" >/dev/null 2>&1; then
    echo "ERROR: swarmfile must define a top-level \"providers\" object." >&2
    exit 1
fi

SWARM_PROMPT=$(jq -r '.prompt // empty' "$CONFIG_FILE")
SWARM_SETUP=$(jq -r '.setup // empty' "$CONFIG_FILE")
MAX_IDLE=$(jq -r '.max_idle // 3' "$CONFIG_FILE")
INJECT_GIT_RULES=$(jq -r 'if has("inject_git_rules") then .inject_git_rules else true end' "$CONFIG_FILE")
GIT_USER_NAME=$(jq -r '.git_user.name // "swarm-agent"' "$CONFIG_FILE")
GIT_USER_EMAIL=$(jq -r '.git_user.email // "agent@swarm.local"' "$CONFIG_FILE")
GIT_SIGNING_KEY=$(jq -r '.git_user.signing_key // empty' "$CONFIG_FILE")
GIT_SIGNING_KEY="$(expand_env_ref "$GIT_SIGNING_KEY")"

# Resolve signing key path and build volume mount.
SIGNING_KEY_ARGS=()
if [ -n "$GIT_SIGNING_KEY" ]; then
    GIT_SIGNING_KEY="${GIT_SIGNING_KEY/#\~/$HOME}"
    if [ ! -f "$GIT_SIGNING_KEY" ]; then
        echo "ERROR: signing key not found: $GIT_SIGNING_KEY" >&2
        exit 1
    fi
    SIGNING_KEY_ARGS=(-v "${GIT_SIGNING_KEY}:/etc/swarm/signing_key:ro")
fi
NUM_AGENTS=$(jq '[.agents[].count] | add' "$CONFIG_FILE")
SWARM_DRIVER_DEFAULT=$(jq -r '.driver // "claude-code"' "$CONFIG_FILE")
MAX_RETRY_WAIT=$(jq -r '.max_retry_wait // 0' "$CONFIG_FILE")

DOCKER_EXTRA_ARGS=()
while IFS= read -r _da; do
    [ -n "$_da" ] && DOCKER_EXTRA_ARGS+=("$_da")
done < <(jq -r '.docker_args[]?' "$CONFIG_FILE" 2>/dev/null)

parse_start_args() {
    OPEN_DASHBOARD=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --dashboard)
                OPEN_DASHBOARD=true
                shift ;;
            *)
                echo "Unknown start option: $1" >&2
                echo "Try '$0 --help' for more." >&2
                exit 1 ;;
        esac
    done
}

cmd_start() {
    # Top-level prompt is optional when every agent group defines its own.
    local all_groups_have_prompt
    all_groups_have_prompt=$(jq \
        '[.agents[] | has("prompt") and (.prompt | length > 0)] | all' \
        "$CONFIG_FILE")

    if [ -z "$SWARM_PROMPT" ] && [ "$all_groups_have_prompt" != "true" ]; then
        echo "ERROR: 'prompt' is missing in ${CONFIG_FILE} (required when not every agent group specifies its own)." >&2
        exit 1
    fi

    if [ -n "$SWARM_PROMPT" ] && [ ! -f "$REPO_ROOT/$SWARM_PROMPT" ]; then
        echo "ERROR: prompt '${SWARM_PROMPT}' not found." >&2
        exit 1
    fi

    # Validate per-group prompt overrides.
    local group_prompts
    group_prompts=$(jq -r '[.agents[].prompt // empty] | unique[]' \
        "$CONFIG_FILE" 2>/dev/null || true)
    while IFS= read -r gp; do
        [ -z "$gp" ] && continue
        if [ ! -f "$REPO_ROOT/$gp" ]; then
            echo "ERROR: per-group prompt ${gp} not found." >&2
            exit 1
        fi
    done <<< "$group_prompts"

    # Refuse to overwrite a bare repo that has unharvested commits.
    if [ -d "$BARE_REPO" ]; then
        BARE_HEAD=$(git -C "$BARE_REPO" rev-parse refs/heads/agent-work 2>/dev/null || true)
        LOCAL_HEAD=$(git rev-parse HEAD 2>/dev/null || true)
        if [ -n "$BARE_HEAD" ] && [ "$BARE_HEAD" != "$LOCAL_HEAD" ]; then
            echo "ERROR: ${BARE_REPO} has unharvested agent commits." >&2
            echo "       Run harvest.sh first, or remove it manually:" >&2
            echo "       rm -rf ${BARE_REPO}" >&2
            exit 1
        fi
    fi

    echo "--- Creating bare repo ---"
    rm_docker_dir "$BARE_REPO"
    git clone --bare "$REPO_ROOT" "$BARE_REPO"

    git -C "$BARE_REPO" branch agent-work HEAD 2>/dev/null || true
    git -C "$BARE_REPO" symbolic-ref HEAD refs/heads/agent-work

    # Allow any UID to push.  The container's "agent" user (UID 1000)
    # may differ from the host UID that created this bare repo.
    git -C "$BARE_REPO" config core.sharedRepository world
    chmod -R a+rwX "$BARE_REPO"

    # Mirror each submodule so containers can init without network.
    cd "$REPO_ROOT"
    git submodule foreach --quiet 'echo "$name|$toplevel/.git/modules/$sm_path"' | \
    while IFS='|' read -r name gitdir; do
        safe_name="${name//\//_}"
        mirror="/tmp/${PROJECT}-mirror-${safe_name}.git"
        rm -rf "$mirror"
        echo "--- Mirroring submodule: ${name} ---"
        git clone --bare "$gitdir" "$mirror"
        chmod -R a+rwX "$mirror"
    done

    # Build per-agent config (model|provider|effort|context|prompt|tag|driver per line).
    # Uses pipe delimiter because bash IFS=$'\t' collapses consecutive tabs.
    AGENTS_CFG="/tmp/${PROJECT}-agents.cfg"
    jq -r '.tag as $dt | .driver as $dd | .agents[] | range(.count) as $i |
        [.model, (.provider // ""), (.effort // ""), (.context // ""), (.prompt // ""), (.tag // $dt // ""), (.driver // $dd // "")] | join("|")' \
        "$CONFIG_FILE" > "$AGENTS_CFG"

    # Preflight: validate all referenced drivers exist before
    # spending time on image build and container startup.
    local _bad_drivers="" _bad_providers="" _checked_drivers=" "
    while IFS='|' read -r _model _provider _effort _context _prompt _tag _drv; do
        _drv="${_drv:-${SWARM_DRIVER_DEFAULT}}"
        if [ -z "$_provider" ]; then
            _bad_providers+="  - agent model ${_model}: missing provider reference\n"
        else
            local _provider_line _provider_kind _provider_api_key
            local _provider_oauth_token _provider_bearer_token _provider_auth_file _provider_base_url
            _provider_line=$(resolve_provider_ref "$CONFIG_FILE" "$_provider")
            if [ -z "$_provider_line" ]; then
                _bad_providers+="  - agent model ${_model}: unknown provider '${_provider}'\n"
            else
                IFS='|' read -r _provider_kind _provider_api_key _provider_oauth_token \
                    _provider_bearer_token _provider_auth_file _provider_base_url <<< "$_provider_line"
                _provider_api_key="$(expand_env_ref "$_provider_api_key")"
                _provider_oauth_token="$(expand_env_ref "$_provider_oauth_token")"
                _provider_bearer_token="$(expand_env_ref "$_provider_bearer_token")"
                _provider_auth_file="$(expand_path_ref "$_provider_auth_file")"
                _provider_base_url="$(expand_env_ref "$_provider_base_url")"
                if ! validate_provider_shape "$_provider" "$_provider_kind" "$_provider_api_key" \
                    "$_provider_oauth_token" "$_provider_bearer_token" "$_provider_auth_file" "$_provider_base_url"; then
                    _bad_providers+="  - agent model ${_model}: invalid provider '${_provider}'\n"
                fi
            fi
        fi
        [[ "$_checked_drivers" == *" $_drv "* ]] && continue
        _checked_drivers+="$_drv "
        if [ ! -f "$SWARM_DIR/lib/drivers/${_drv}.sh" ]; then
            _bad_drivers+="  - ${_drv}\n"
            continue
        fi
        load_launch_driver "$_drv"
    done < "$AGENTS_CFG"
    if [ -n "$_bad_drivers" ]; then
        printf "ERROR: unknown driver(s):\n%b" "$_bad_drivers" >&2
        echo "Available drivers: $(ls "$SWARM_DIR/lib/drivers/" | sed 's/\.sh$//' | tr '\n' ' ')" >&2
        exit 1
    fi
    if [ -n "$_bad_providers" ]; then
        printf "ERROR: provider configuration error(s):\n%b" "$_bad_providers" >&2
        exit 1
    fi

    # Derive the set of agent CLIs to install from referenced drivers.
    local _swarm_agents=""
    local _seen_agents=" "
    while IFS='|' read -r _ _ _ _ _ _ _drv; do
        _drv="${_drv:-${SWARM_DRIVER_DEFAULT}}"
        [[ "$_seen_agents" == *" $_drv "* ]] && continue
        _seen_agents+="$_drv "
        _swarm_agents="${_swarm_agents:+${_swarm_agents},}${_drv}"
    done < "$AGENTS_CFG"
    local _pp_drv
    _pp_drv=$(jq -r '.post_process.driver // .driver // "claude-code"' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ "$_seen_agents" != *" $_pp_drv "* ]]; then
        _swarm_agents="${_swarm_agents:+${_swarm_agents},}${_pp_drv}"
    fi

    local _cc_version
    _cc_version=$(jq -r '.claude_code_version // empty' "$CONFIG_FILE" 2>/dev/null || true)

    echo "--- Building agent image (agents: ${_swarm_agents}) ---"
    docker build -t "$IMAGE_NAME" \
        --build-arg "SWARM_AGENTS=${_swarm_agents}" \
        ${_cc_version:+--build-arg "CLAUDE_CODE_VERSION=${_cc_version}"} \
        -f "$SWARM_DIR/Dockerfile" "$SWARM_DIR"

    # Build mirror volume args from discovered submodules.
    git submodule foreach --quiet 'echo "$name"' | while read -r name; do
        safe_name="${name//\//_}"
        mirror="/tmp/${PROJECT}-mirror-${safe_name}.git"
        echo "-v ${mirror}:/mirrors/${name}:ro"
    done > "/tmp/${PROJECT}-mirror-vols.txt"

    # Read mirror volume mounts (shared across all containers).
    MIRROR_ARGS=()
    while read -r line; do
        # shellcheck disable=SC2206
        MIRROR_ARGS+=($line)
    done < "/tmp/${PROJECT}-mirror-vols.txt"

    AGENT_IDX=0
    while IFS='|' read -r agent_model agent_provider agent_effort agent_context agent_prompt agent_tag agent_driver; do
        AGENT_IDX=$((AGENT_IDX + 1))
        NAME="${IMAGE_NAME}-${AGENT_IDX}"
        docker rm -f "$NAME" 2>/dev/null || true
        agent_tag="$(expand_env_ref "$agent_tag")"
        agent_context="${agent_context:-full}"
        agent_driver="${agent_driver:-${SWARM_DRIVER_DEFAULT}}"

        local provider_line provider_kind provider_api_key provider_oauth_token
        local provider_bearer_token provider_auth_file provider_base_url
        provider_line=$(resolve_provider_ref "$CONFIG_FILE" "$agent_provider")
        if [ -z "$provider_line" ]; then
            echo "ERROR: unknown provider '${agent_provider}'." >&2
            exit 1
        fi
        IFS='|' read -r provider_kind provider_api_key provider_oauth_token \
            provider_bearer_token provider_auth_file provider_base_url <<< "$provider_line"
        provider_api_key="$(expand_env_ref "$provider_api_key")"
        provider_oauth_token="$(expand_env_ref "$provider_oauth_token")"
        provider_bearer_token="$(expand_env_ref "$provider_bearer_token")"
        provider_auth_file="$(expand_path_ref "$provider_auth_file")"
        provider_base_url="$(expand_env_ref "$provider_base_url")"
        validate_provider_shape "$agent_provider" "$provider_kind" "$provider_api_key" \
            "$provider_oauth_token" "$provider_bearer_token" "$provider_auth_file" "$provider_base_url"

        load_launch_driver "$agent_driver"
        agent_validate_config "$agent_model" "$agent_provider" "$provider_kind" \
            "$provider_api_key" "$provider_oauth_token" "$provider_bearer_token" \
            "$provider_auth_file" "$provider_base_url" "$agent_effort"
        local effective_prompt="${agent_prompt:-$SWARM_PROMPT}"

        local ctx_label="" prompt_label="" driver_label=""
        [ "$agent_context" != "full" ] && ctx_label=" context=${agent_context}"
        [ -n "$agent_prompt" ] && prompt_label=" prompt=${agent_prompt}"
        [ "$agent_driver" != "claude-code" ] && driver_label=" driver=${agent_driver}"
        echo "--- Launching ${NAME} (${agent_model}${agent_effort:+ effort=${agent_effort}} provider=${agent_provider}${ctx_label}${prompt_label}${driver_label}) ---"
        EXTRA_ENV=()

        EXTRA_ENV+=(-e "SWARM_PROVIDER_NAME=${agent_provider}")
        EXTRA_ENV+=(-e "SWARM_PROVIDER_KIND=${provider_kind}")
        EXTRA_ENV+=(-e "SWARM_PROVIDER_API_KEY=${provider_api_key}")
        EXTRA_ENV+=(-e "SWARM_PROVIDER_OAUTH_TOKEN=${provider_oauth_token}")
        EXTRA_ENV+=(-e "SWARM_PROVIDER_BEARER_TOKEN=${provider_bearer_token}")
        EXTRA_ENV+=(-e "SWARM_PROVIDER_BASE_URL=${provider_base_url}")

        # Delegate auth credential resolution to the driver.
        while IFS= read -r _ae; do
            [ -n "$_ae" ] && EXTRA_ENV+=("$_ae")
        done < <(agent_docker_auth "$agent_provider" "$provider_kind" "$provider_api_key" \
            "$provider_oauth_token" "$provider_bearer_token" "$provider_auth_file" "$provider_base_url")

        local eff="${agent_effort:-}"
        if [ -n "$eff" ]; then
            while IFS= read -r _de; do
                [ -n "$_de" ] && EXTRA_ENV+=("$_de")
            done < <(agent_docker_env "$eff")
        fi

        local price_input="" price_output="" price_cached=""
        local _price
        _price=$(jq -r --arg m "$agent_model" \
            '.pricing[$m] // empty | "\(.input + 0) \(.output + 0) \((.cached // 0) + 0)"' \
            "$CONFIG_FILE" 2>/dev/null || true)
        if [ -n "$_price" ]; then
            read -r price_input price_output price_cached <<< "$_price"
        fi

        docker run -d \
            --name "$NAME" \
            -v "${BARE_REPO}:/upstream:rw" \
            "${MIRROR_ARGS[@]+"${MIRROR_ARGS[@]}"}" \
            "${SIGNING_KEY_ARGS[@]+"${SIGNING_KEY_ARGS[@]}"}" \
            "${DOCKER_EXTRA_ARGS[@]+"${DOCKER_EXTRA_ARGS[@]}"}" \
            "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
            -e "SWARM_MODEL=${agent_model}" \
            -e "SWARM_EFFORT=${eff}" \
            -e "CLAUDE_MODEL=${agent_model}" \
            -e "SWARM_PROMPT=${effective_prompt}" \
            -e "SWARM_SETUP=${SWARM_SETUP}" \
            -e "MAX_IDLE=${MAX_IDLE}" \
            -e "MAX_RETRY_WAIT=${MAX_RETRY_WAIT}" \
            -e "GIT_USER_NAME=${GIT_USER_NAME}" \
            -e "GIT_USER_EMAIL=${GIT_USER_EMAIL}" \
            -e "INJECT_GIT_RULES=${INJECT_GIT_RULES}" \
            -e "AGENT_ID=${AGENT_IDX}" \
            -e "SWARM_TAG=${agent_tag}" \
            -e "SWARM_CONTEXT=${agent_context}" \
            -e "SWARM_DRIVER=${agent_driver}" \
            -e "SWARM_RUN_CONTEXT=${SWARM_RUN_CONTEXT}" \
            -e "SWARM_CFG_PROMPT=${effective_prompt}" \
            -e "SWARM_CFG_SETUP=${SWARM_SETUP}" \
            -e "SWARM_ACTIVITY_TIMEOUT=${SWARM_ACTIVITY_TIMEOUT:-0}" \
            -e "SWARM_ACTIVITY_POLL=${SWARM_ACTIVITY_POLL:-10}" \
            -e "SWARM_WATCHDOG_GRACE=${SWARM_WATCHDOG_GRACE:-10}" \
            ${price_input:+-e "SWARM_PRICE_INPUT=${price_input}"} \
            ${price_output:+-e "SWARM_PRICE_OUTPUT=${price_output}"} \
            ${price_cached:+-e "SWARM_PRICE_CACHED=${price_cached}"} \
            "$IMAGE_NAME"
    done < "$AGENTS_CFG"

    rm -f "/tmp/${PROJECT}-mirror-vols.txt" "/tmp/${PROJECT}-agents.cfg"

    # Write state file so a standalone dashboard can pick up config.
    local state_model_summary state_config_label
    state_model_summary=$(jq -r \
        '(.prompt // "") as $dp | ($dp | split("/") | .[-1] // "" | rtrimstr(".md")) as $dp_stem |
        [.agents[] |
          "\(.count)x \(.model | split("/") | .[-1])" +
          (if .context == "none" then " ctx:bare"
           elif .context == "slim" then " ctx:slim"
           else "" end) +
          (if .prompt and .prompt != $dp then
            ":" + (.prompt | split("/") | .[-1] | rtrimstr(".md") |
              if startswith($dp_stem + "-") then .[$dp_stem | length + 1:] else . end)
           else "" end)] | join(", ")' \
        "$CONFIG_FILE")
    state_config_label=$(basename "$CONFIG_FILE")
    local config_title
    config_title=$(jq -r '.title // empty' "$CONFIG_FILE" 2>/dev/null || true)
    cat > "/tmp/${PROJECT}-swarm.env" <<ENVEOF
SWARM_TITLE="${SWARM_TITLE:-${config_title}}"
SWARM_CONFIG="${CONFIG_FILE}"
SWARM_NUM_AGENTS="${NUM_AGENTS}"
SWARM_MODEL_SUMMARY="${state_model_summary}"
SWARM_CONFIG_LABEL="${state_config_label}"
ENVEOF

    echo ""
    echo "--- ${NUM_AGENTS} agents launched ---"
    echo ""
    echo "Monitor:"
    echo "  $0 status"
    echo "  $0 logs 1"
    echo ""
    echo "Stop:"
    echo "  $0 stop"
    echo ""
    echo "Bare repo: ${BARE_REPO}"
}

cmd_stop() {
    echo "--- Stopping agents ---"
    for i in $(seq 1 "$NUM_AGENTS"); do
        NAME="${IMAGE_NAME}-${i}"
        docker stop "$NAME" 2>/dev/null && echo "  stopped ${NAME}" \
            || echo "  ${NAME} not running"
    done
    rm -f "/tmp/${PROJECT}-swarm.env"
}

cmd_logs() {
    local n="${1:-1}"
    docker logs -f "${IMAGE_NAME}-${n}"
}

cmd_status() {
    for i in $(seq 1 "$NUM_AGENTS"); do
        NAME="${IMAGE_NAME}-${i}"
        printf "%-30s " "${NAME}:"
        docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null \
            || echo "not found"
    done
}

cmd_wait() {
    echo "--- Waiting for all agents to finish ---"

    while true; do
        sleep 10
        local all_done=true running=0 exited=0
        for i in $(seq 1 "$NUM_AGENTS"); do
            local state
            state=$(docker inspect -f '{{.State.Status}}' "${IMAGE_NAME}-${i}" 2>/dev/null || echo "not found")
            case "$state" in
                running) running=$((running + 1)); all_done=false ;;
                exited)  exited=$((exited + 1)) ;;
            esac
        done

        printf "\r  %d running, %d exited " "$running" "$exited"

        if $all_done; then
            echo ""
            echo "All agents finished."
            break
        fi
    done

    local pp_prompt
    pp_prompt=$(jq -r '.post_process.prompt // empty' "$CONFIG_FILE")
    if [ -n "$pp_prompt" ]; then
        echo ""
        cmd_post_process
        return
    fi

    echo ""
    echo "--- Harvesting results ---"
    "$SWARM_DIR/harvest.sh"
}

cmd_post_process() {
    local pp_prompt pp_model pp_provider pp_effort pp_tag pp_driver pp_max_idle
    pp_prompt=$(jq -r '.post_process.prompt // empty' "$CONFIG_FILE")
    pp_max_idle=$(jq -r '.post_process.max_idle // .max_idle // 3' "$CONFIG_FILE")
    pp_model=$(jq -r '.post_process.model // "claude-opus-4-6"' "$CONFIG_FILE")
    pp_provider=$(jq -r '.post_process.provider // empty' "$CONFIG_FILE")
    pp_effort=$(jq -r '.post_process.effort // empty' "$CONFIG_FILE")
    pp_tag=$(jq -r '.post_process.tag // .tag // empty' "$CONFIG_FILE")
    pp_tag="$(expand_env_ref "$pp_tag")"
    pp_driver=$(jq -r '.post_process.driver // .driver // "claude-code"' "$CONFIG_FILE")

    if [ -z "$pp_prompt" ]; then
        echo "ERROR: post_process.prompt is not set in ${CONFIG_FILE}." >&2
        exit 1
    fi
    if [ -z "$pp_provider" ]; then
        echo "ERROR: post_process.provider is required when post_process is configured." >&2
        exit 1
    fi

    if [ ! -d "$BARE_REPO" ]; then
        echo "--- Creating bare repo for post-process ---"
        git clone --bare "$REPO_ROOT" "$BARE_REPO"
        git -C "$BARE_REPO" branch agent-work HEAD 2>/dev/null || true
        git -C "$BARE_REPO" symbolic-ref HEAD refs/heads/agent-work
        git -C "$BARE_REPO" config core.sharedRepository world
        chmod -R a+rwX "$BARE_REPO"
    fi

    local NAME="${IMAGE_NAME}-post"
    docker rm -f "$NAME" 2>/dev/null || true

    # Build mirror volume args from existing mirrors.
    local MIRROR_ARGS=()
    cd "$REPO_ROOT"
    git submodule foreach --quiet 'echo "$name"' 2>/dev/null | while read -r name; do
        local safe_name="${name//\//_}"
        local mirror="/tmp/${PROJECT}-mirror-${safe_name}.git"
        if [ -d "$mirror" ]; then
            echo "-v ${mirror}:/mirrors/${name}:ro"
        fi
    done > "/tmp/${PROJECT}-pp-vols.txt"
    while read -r line; do
        # shellcheck disable=SC2206
        MIRROR_ARGS+=($line)
    done < "/tmp/${PROJECT}-pp-vols.txt"
    rm -f "/tmp/${PROJECT}-pp-vols.txt"

    local pp_provider_line pp_provider_kind pp_provider_api_key pp_provider_oauth_token
    local pp_provider_bearer_token pp_provider_auth_file pp_provider_base_url
    pp_provider_line=$(resolve_provider_ref "$CONFIG_FILE" "$pp_provider")
    if [ -z "$pp_provider_line" ]; then
        echo "ERROR: unknown post-process provider '${pp_provider}'." >&2
        exit 1
    fi
    IFS='|' read -r pp_provider_kind pp_provider_api_key pp_provider_oauth_token \
        pp_provider_bearer_token pp_provider_auth_file pp_provider_base_url <<< "$pp_provider_line"
    pp_provider_api_key="$(expand_env_ref "$pp_provider_api_key")"
    pp_provider_oauth_token="$(expand_env_ref "$pp_provider_oauth_token")"
    pp_provider_bearer_token="$(expand_env_ref "$pp_provider_bearer_token")"
    pp_provider_auth_file="$(expand_path_ref "$pp_provider_auth_file")"
    pp_provider_base_url="$(expand_env_ref "$pp_provider_base_url")"
    validate_provider_shape "$pp_provider" "$pp_provider_kind" "$pp_provider_api_key" \
        "$pp_provider_oauth_token" "$pp_provider_bearer_token" "$pp_provider_auth_file" "$pp_provider_base_url"

    load_launch_driver "$pp_driver"
    agent_validate_config "$pp_model" "$pp_provider" "$pp_provider_kind" \
        "$pp_provider_api_key" "$pp_provider_oauth_token" "$pp_provider_bearer_token" \
        "$pp_provider_auth_file" "$pp_provider_base_url" "$pp_effort"

    local EXTRA_ENV=()
    EXTRA_ENV+=(-e "SWARM_PROVIDER_NAME=${pp_provider}")
    EXTRA_ENV+=(-e "SWARM_PROVIDER_KIND=${pp_provider_kind}")
    EXTRA_ENV+=(-e "SWARM_PROVIDER_API_KEY=${pp_provider_api_key}")
    EXTRA_ENV+=(-e "SWARM_PROVIDER_OAUTH_TOKEN=${pp_provider_oauth_token}")
    EXTRA_ENV+=(-e "SWARM_PROVIDER_BEARER_TOKEN=${pp_provider_bearer_token}")
    EXTRA_ENV+=(-e "SWARM_PROVIDER_BASE_URL=${pp_provider_base_url}")
    while IFS= read -r _ae; do
        [ -n "$_ae" ] && EXTRA_ENV+=("$_ae")
    done < <(agent_docker_auth "$pp_provider" "$pp_provider_kind" "$pp_provider_api_key" \
        "$pp_provider_oauth_token" "$pp_provider_bearer_token" "$pp_provider_auth_file" "$pp_provider_base_url")

    if [ -n "$pp_effort" ]; then
        while IFS= read -r _de; do
            [ -n "$_de" ] && EXTRA_ENV+=("$_de")
        done < <(agent_docker_env "$pp_effort")
    fi

    local price_input="" price_output="" price_cached=""
    local _price
    _price=$(jq -r --arg m "$pp_model" \
        '.pricing[$m] // empty | "\(.input + 0) \(.output + 0) \((.cached // 0) + 0)"' \
        "$CONFIG_FILE" 2>/dev/null || true)
    if [ -n "$_price" ]; then
        read -r price_input price_output price_cached <<< "$_price"
    fi

    echo "--- Starting post-processing (${pp_model}) ---"
    docker run -d \
        --name "$NAME" \
        -v "${BARE_REPO}:/upstream:rw" \
        "${MIRROR_ARGS[@]+"${MIRROR_ARGS[@]}"}" \
        "${SIGNING_KEY_ARGS[@]+"${SIGNING_KEY_ARGS[@]}"}" \
        "${DOCKER_EXTRA_ARGS[@]+"${DOCKER_EXTRA_ARGS[@]}"}" \
        "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
        -e "SWARM_MODEL=${pp_model}" \
        -e "SWARM_EFFORT=${pp_effort}" \
        -e "CLAUDE_MODEL=${pp_model}" \
        -e "SWARM_PROMPT=${pp_prompt}" \
        -e "SWARM_SETUP=${SWARM_SETUP:-}" \
        -e "MAX_IDLE=${pp_max_idle}" \
        -e "MAX_RETRY_WAIT=${MAX_RETRY_WAIT}" \
        -e "GIT_USER_NAME=${GIT_USER_NAME}" \
        -e "GIT_USER_EMAIL=${GIT_USER_EMAIL}" \
        -e "INJECT_GIT_RULES=${INJECT_GIT_RULES}" \
        -e "AGENT_ID=post" \
        -e "SWARM_TAG=${pp_tag}" \
        -e "SWARM_DRIVER=${pp_driver}" \
        -e "SWARM_RUN_CONTEXT=${SWARM_RUN_CONTEXT}" \
        -e "SWARM_CFG_PROMPT=${pp_prompt}" \
        -e "SWARM_CFG_SETUP=${SWARM_SETUP:-}" \
        -e "SWARM_ACTIVITY_TIMEOUT=${SWARM_ACTIVITY_TIMEOUT:-0}" \
        -e "SWARM_ACTIVITY_POLL=${SWARM_ACTIVITY_POLL:-10}" \
        -e "SWARM_WATCHDOG_GRACE=${SWARM_WATCHDOG_GRACE:-10}" \
        ${price_input:+-e "SWARM_PRICE_INPUT=${price_input}"} \
        ${price_output:+-e "SWARM_PRICE_OUTPUT=${price_output}"} \
        ${price_cached:+-e "SWARM_PRICE_CACHED=${price_cached}"} \
        "$IMAGE_NAME"

    echo "Post-processing agent launched: ${NAME}"
    echo "Waiting for completion..."

    while true; do
        sleep 10
        local state
        state=$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null || echo "not found")
        if [ "$state" = "running" ]; then
            printf "."
            continue
        fi
        echo ""
        echo "Post-processing agent finished (${state})."
        break
    done

    echo ""
    echo "--- Harvesting results ---"
    "$SWARM_DIR/harvest.sh"
}

case "${1:-start}" in
    start)
        shift
        parse_start_args "$@"
        cmd_start
        if $OPEN_DASHBOARD; then
            exec "$SWARM_DIR/dashboard.sh"
        fi
        ;;
    stop)          cmd_stop ;;
    logs)          cmd_logs "${2:-1}" ;;
    status)        cmd_status ;;
    wait)          cmd_wait ;;
    post-process)  cmd_post_process ;;
    *)
        echo "Usage: $0 {start|stop|logs N|status|wait|post-process}" >&2
        echo "Try '$0 --help' for more information." >&2
        exit 1
        ;;
esac
