#!/bin/bash
# shellcheck disable=SC2034
set -euo pipefail

# Unit tests for launch-time parsing and provider validation.
# No Docker or API keys required.

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
DRIVERS_DIR="$TESTS_DIR/../lib/drivers"

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: ${label}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${label}"
        echo "        expected: ${expected}"
        echo "        actual:   ${actual}"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        echo "  PASS: ${label}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${label}"
        echo "        expected to contain: ${needle}"
        echo "        actual:              ${haystack}"
        FAIL=$((FAIL + 1))
    fi
}

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
    ' "$config_file"
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
            [ -n "$bearer_token" ] && return 1
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

parse_agents_cfg() {
    jq -r '
        .tag as $dt | .driver as $dd | .agents[] | range(.count) as $i |
        [.model, (.provider // ""), (.effort // ""), (.context // ""), (.prompt // ""), (.tag // $dt // ""), (.driver // $dd // "")] | join("|")
    ' "$1"
}

derive_swarm_agents() {
    local config_file="$1"
    local default_driver seen out pp_driver
    default_driver=$(jq -r '.driver // "claude-code"' "$config_file")
    seen=" "
    out=""

    while IFS='|' read -r _ _ _ _ _ _ driver; do
        driver="${driver:-$default_driver}"
        [[ "$seen" == *" $driver "* ]] && continue
        seen+=" $driver "
        out="${out:+${out},}${driver}"
    done < <(parse_agents_cfg "$config_file")

    pp_driver=$(jq -r '.post_process.driver // .driver // "claude-code"' "$config_file")
    if [[ "$seen" != *" $pp_driver "* ]]; then
        out="${out:+${out},}${pp_driver}"
    fi
    printf '%s' "$out"
}

validate_driver_cfg() {
    local driver="$1" model="$2" provider_ref="$3" kind="$4" api_key="$5"
    local oauth_token="$6" bearer_token="$7" auth_file="$8" base_url="$9" effort="${10}"
    # shellcheck source=/dev/null
    source "$DRIVERS_DIR/${driver}.sh"
    agent_validate_config "$model" "$provider_ref" "$kind" "$api_key" \
        "$oauth_token" "$bearer_token" "$auth_file" "$base_url" "$effort"
}

# ============================================================
echo "=== 1. Environment and path expansion ==="

export SWARM_TEST_TOKEN="swarm-token"
assert_eq "expand env ref" "swarm-token" "$(expand_env_ref '$SWARM_TEST_TOKEN')"
assert_eq "expand literal" "literal" "$(expand_env_ref 'literal')"
assert_eq "expand unset env ref" "" "$(expand_env_ref '$SWARM_MISSING_TOKEN')"
assert_eq "expand tilde path" "${HOME}/.codex/auth.json" "$(expand_path_ref '~/.codex/auth.json')"

# ============================================================
echo ""
echo "=== 2. Legacy auth detection ==="

cat > "$TMPDIR/legacy.json" <<'EOF'
{
  "providers": {
    "p": { "kind": "anthropic", "oauth_token": "$CLAUDE_CODE_OAUTH_TOKEN" }
  },
  "agents": [
    { "count": 1, "model": "claude-opus-4-6", "provider": "p", "auth": "oauth" }
  ]
}
EOF

cat > "$TMPDIR/v2.json" <<'EOF'
{
  "providers": {
    "p": { "kind": "anthropic", "oauth_token": "$CLAUDE_CODE_OAUTH_TOKEN" }
  },
  "agents": [
    { "count": 1, "model": "claude-opus-4-6", "provider": "p" }
  ]
}
EOF

assert_eq "legacy fields detected" "true" "$({ has_legacy_auth_fields "$TMPDIR/legacy.json" && echo true; } || echo false)"
assert_eq "v2 fields not detected as legacy" "false" "$({ has_legacy_auth_fields "$TMPDIR/v2.json" && echo true; } || echo false)"

# ============================================================
echo ""
echo "=== 3. Provider resolution and validation ==="

AUTH_FILE="$TMPDIR/auth.json"
echo '{"tokens":{"access":"test"}}' > "$AUTH_FILE"

cat > "$TMPDIR/providers.json" <<EOF
{
  "providers": {
    "none": { "kind": "none" },
    "anthropic_key": { "kind": "anthropic", "api_key": "\$ANTHROPIC_API_KEY" },
    "anthropic_oauth": { "kind": "anthropic", "oauth_token": "\$CLAUDE_CODE_OAUTH_TOKEN" },
    "anthropic_file": { "kind": "anthropic", "auth_file": "$AUTH_FILE" },
    "openrouter": {
      "kind": "anthropic-compatible",
      "base_url": "https://openrouter.ai/api",
      "bearer_token": "\$OPENROUTER_API_KEY"
    },
    "anthropic_proxy_file": {
      "kind": "anthropic-compatible",
      "base_url": "https://proxy.example.com",
      "auth_file": "$AUTH_FILE"
    },
    "openai_key": { "kind": "openai", "api_key": "\$OPENAI_API_KEY" },
    "openai_file": { "kind": "openai", "auth_file": "$AUTH_FILE" },
    "openai_proxy": {
      "kind": "openai-compatible",
      "base_url": "https://api.example.com/v1",
      "auth_file": "$AUTH_FILE"
    },
    "gemini_key": { "kind": "gemini", "api_key": "\$GEMINI_API_KEY" },
    "kimi_key": {
      "kind": "kimi",
      "api_key": "\$KIMI_API_KEY",
      "base_url": "https://api.kimi.com/coding/v1"
    },
    "factory_key": { "kind": "factory", "api_key": "\$FACTORY_API_KEY" }
  }
}
EOF

export ANTHROPIC_API_KEY="sk-ant"
export CLAUDE_CODE_OAUTH_TOKEN="sk-oauth"
export OPENROUTER_API_KEY="sk-or"
export OPENAI_API_KEY="sk-openai"
export GEMINI_API_KEY="sk-gem"
export KIMI_API_KEY="sk-kimi"
export FACTORY_API_KEY="sk-factory"

for provider in none anthropic_key anthropic_oauth anthropic_file openrouter anthropic_proxy_file openai_key openai_file openai_proxy gemini_key kimi_key factory_key; do
    line=$(resolve_provider_ref "$TMPDIR/providers.json" "$provider")
    IFS='|' read -r kind api_key oauth_token bearer_token auth_file base_url <<< "$line"
    api_key="$(expand_env_ref "$api_key")"
    oauth_token="$(expand_env_ref "$oauth_token")"
    bearer_token="$(expand_env_ref "$bearer_token")"
    auth_file="$(expand_path_ref "$auth_file")"
    base_url="$(expand_env_ref "$base_url")"
    assert_eq "${provider} validates" "ok" \
        "$(validate_provider_shape "$provider" "$kind" "$api_key" "$oauth_token" "$bearer_token" "$auth_file" "$base_url" >/dev/null 2>&1 && echo ok || echo fail)"
done

assert_eq "resolve anthropic_key raw value" 'anthropic|$ANTHROPIC_API_KEY|||' \
    "$(resolve_provider_ref "$TMPDIR/providers.json" "anthropic_key" | cut -d'|' -f1-5)"
assert_eq "resolve unknown provider empty" "" "$(resolve_provider_ref "$TMPDIR/providers.json" "missing")"

# ============================================================
echo ""
echo "=== 4. Invalid provider shapes are rejected ==="

assert_eq "missing kind rejected" "fail" \
    "$(validate_provider_shape "bad" "" "" "" "" "" "" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "none rejects auth" "fail" \
    "$(validate_provider_shape "bad" "none" "sk" "" "" "" "" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "anthropic rejects multiple auth sources" "fail" \
    "$(validate_provider_shape "bad" "anthropic" "sk" "tok" "" "" "" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "anthropic-compatible requires base_url" "fail" \
    "$(validate_provider_shape "bad" "anthropic-compatible" "" "" "tok" "" "" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "openai-compatible requires base_url" "fail" \
    "$(validate_provider_shape "bad" "openai-compatible" "sk" "" "" "" "" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "gemini rejects base_url" "fail" \
    "$(validate_provider_shape "bad" "gemini" "sk" "" "" "" "https://x" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "missing auth file rejected" "fail" \
    "$(validate_provider_shape "bad" "openai" "" "" "" "$TMPDIR/nope.json" "" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "unknown provider kind rejected" "fail" \
    "$(validate_provider_shape "bad" "mystery" "" "" "" "" "" >/dev/null 2>&1 && echo ok || echo fail)"

# ============================================================
echo ""
echo "=== 5. Agents CFG and install-set derivation ==="

cat > "$TMPDIR/swarm.json" <<'EOF'
{
  "driver": "claude-code",
  "tag": "top",
  "providers": {
    "anthropic_oauth": { "kind": "anthropic", "oauth_token": "$CLAUDE_CODE_OAUTH_TOKEN" },
    "gemini_key": { "kind": "gemini", "api_key": "$GEMINI_API_KEY" },
    "openai_key": { "kind": "openai", "api_key": "$OPENAI_API_KEY" }
  },
  "agents": [
    { "count": 2, "model": "claude-opus-4-6", "provider": "anthropic_oauth" },
    { "count": 1, "model": "gemini-2.5-pro", "provider": "gemini_key", "driver": "gemini-cli", "context": "slim" },
    { "count": 1, "model": "gpt-5.4", "provider": "openai_key", "driver": "codex-cli", "prompt": "prompts/review.md", "tag": "review" }
  ],
  "post_process": {
    "prompt": "prompts/post.md",
    "model": "anthropic/claude-sonnet-4-5-20250929",
    "provider": "anthropic_oauth",
    "driver": "opencode"
  }
}
EOF

CFG=$(parse_agents_cfg "$TMPDIR/swarm.json")
assert_eq "agents cfg line count" "4" "$(echo "$CFG" | wc -l | tr -d ' ')"

LINE1=$(echo "$CFG" | sed -n '1p')
LINE3=$(echo "$CFG" | sed -n '3p')
LINE4=$(echo "$CFG" | sed -n '4p')
IFS='|' read -r model1 provider1 effort1 context1 prompt1 tag1 driver1 <<< "$LINE1"
IFS='|' read -r model3 provider3 effort3 context3 prompt3 tag3 driver3 <<< "$LINE3"
IFS='|' read -r model4 provider4 effort4 context4 prompt4 tag4 driver4 <<< "$LINE4"

assert_eq "agent1 provider" "anthropic_oauth" "$provider1"
assert_eq "agent1 tag inherits top-level" "top" "$tag1"
assert_eq "agent1 driver inherits default" "claude-code" "$driver1"
assert_eq "agent3 context" "slim" "$context3"
assert_eq "agent3 driver" "gemini-cli" "$driver3"
assert_eq "agent4 prompt" "prompts/review.md" "$prompt4"
assert_eq "agent4 tag override" "review" "$tag4"
assert_eq "agent4 driver" "codex-cli" "$driver4"

assert_eq "derived SWARM_AGENTS" "claude-code,gemini-cli,codex-cli,opencode" "$(derive_swarm_agents "$TMPDIR/swarm.json")"

# ============================================================
echo ""
echo "=== 6. Driver launch validation uses provider contract ==="

assert_eq "claude accepts anthropic oauth" "ok" \
    "$(validate_driver_cfg "claude-code" "claude-opus-4-6" "anthropic_oauth" "anthropic" "" "sk-oauth" "" "" "" "high" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "claude accepts anthropic-compatible bearer" "ok" \
    "$(validate_driver_cfg "claude-code" "openai/gpt-5.4" "openrouter" "anthropic-compatible" "" "" "sk-or" "" "https://openrouter.ai/api" "" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "claude rejects auth_file" "fail" \
    "$(validate_driver_cfg "claude-code" "claude-opus-4-6" "anthropic_file" "anthropic" "" "" "" "$AUTH_FILE" "" "" >/dev/null 2>&1 && echo ok || echo fail)"

assert_eq "codex accepts api_key" "ok" \
    "$(validate_driver_cfg "codex-cli" "gpt-5.4" "openai_key" "openai" "sk-openai" "" "" "" "" "" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "codex accepts auth_file" "ok" \
    "$(validate_driver_cfg "codex-cli" "gpt-5.4" "openai_file" "openai" "" "" "" "$AUTH_FILE" "" "" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "codex rejects wrong kind" "fail" \
    "$(validate_driver_cfg "codex-cli" "gpt-5.4" "anthropic_key" "anthropic" "sk" "" "" "" "" "" >/dev/null 2>&1 && echo ok || echo fail)"

assert_eq "gemini accepts gemini key" "ok" \
    "$(validate_driver_cfg "gemini-cli" "gemini-2.5-pro" "gemini_key" "gemini" "sk-gem" "" "" "" "" "" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "gemini rejects base_url" "fail" \
    "$(validate_driver_cfg "gemini-cli" "gemini-2.5-pro" "gemini_key" "gemini" "sk-gem" "" "" "" "https://x" "" >/dev/null 2>&1 && echo ok || echo fail)"

assert_eq "kimi accepts kimi key" "ok" \
    "$(validate_driver_cfg "kimi-cli" "kimi-for-coding" "kimi_key" "kimi" "sk-kimi" "" "" "" "https://api.kimi.com/coding/v1" "off" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "kimi rejects oauth token" "fail" \
    "$(validate_driver_cfg "kimi-cli" "kimi-for-coding" "kimi_key" "kimi" "" "tok" "" "" "" "" >/dev/null 2>&1 && echo ok || echo fail)"

assert_eq "opencode accepts anthropic oauth" "ok" \
    "$(validate_driver_cfg "opencode" "anthropic/claude-sonnet-4-5-20250929" "anthropic_oauth" "anthropic" "" "sk-oauth" "" "" "" "high" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "opencode accepts openai-compatible auth_file" "ok" \
    "$(validate_driver_cfg "opencode" "proxy/gpt-5.4" "proxy" "openai-compatible" "" "" "" "$AUTH_FILE" "https://api.example.com/v1" "" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "opencode rejects wrong model prefix" "fail" \
    "$(validate_driver_cfg "opencode" "openai/gpt-5.4" "proxy" "openai-compatible" "sk" "" "" "" "https://api.example.com/v1" "" >/dev/null 2>&1 && echo ok || echo fail)"

assert_eq "droid accepts factory key" "ok" \
    "$(validate_driver_cfg "droid" "glm-4.7" "factory_key" "factory" "sk-factory" "" "" "" "" "medium" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "droid rejects non-factory kind" "fail" \
    "$(validate_driver_cfg "droid" "glm-4.7" "openai_key" "openai" "sk-openai" "" "" "" "" "" >/dev/null 2>&1 && echo ok || echo fail)"

assert_eq "fake accepts none provider" "ok" \
    "$(validate_driver_cfg "fake" "fake-model" "none" "none" "" "" "" "" "" "" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "fake rejects auth" "fail" \
    "$(validate_driver_cfg "fake" "fake-model" "none" "none" "sk" "" "" "" "" "" >/dev/null 2>&1 && echo ok || echo fail)"

# ============================================================
echo ""
echo "=== 7. parse_start_args ==="

_LAUNCH="$TESTS_DIR/../launch.sh"
eval "$(sed -n '/^parse_start_args()/,/^}/p' "$_LAUNCH")"

parse_start_args --dashboard
assert_eq "dashboard flag sets OPEN_DASHBOARD" "true" "$OPEN_DASHBOARD"

parse_start_args
assert_eq "dashboard default false" "false" "$OPEN_DASHBOARD"

if (parse_start_args --bogus 2>/dev/null); then
    echo "  FAIL: unknown start option should fail"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: unknown start option rejected"
    PASS=$((PASS + 1))
fi

echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
