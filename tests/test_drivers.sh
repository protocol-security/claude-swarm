#!/bin/bash
# shellcheck disable=SC2034
set -euo pipefail

# Unit tests for the driver role interface under the v2 provider contract.
# No Docker or live API access required.

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
DRIVERS_DIR="$TESTS_DIR/../lib/drivers"
FILTER_DIR="$TESTS_DIR/../lib"

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

assert_not_empty() {
    local label="$1" value="$2"
    if [ -n "$value" ]; then
        echo "  PASS: ${label}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${label} (value was empty)"
        FAIL=$((FAIL + 1))
    fi
}

load_driver() {
    # shellcheck source=/dev/null
    source "$DRIVERS_DIR/$1.sh"
}

render_with_filter() {
    local jq_file="$1" input="$2"
    printf '%s\n' "$input" \
        | AGENT_ID=7 SWARM_JQ_FILTER_FILE="$jq_file" \
            bash "$FILTER_DIR/activity-filter.sh" 2>/dev/null || true
}

assert_driver_interface() {
    local driver="$1"
    local required_fns=(
        agent_default_model agent_name agent_cmd agent_version
        agent_run agent_settings agent_extract_stats agent_detect_fatal
        agent_is_retriable agent_activity_jq agent_docker_env
        agent_docker_auth agent_validate_config agent_install_cmd
    )
    load_driver "$driver"
    for fn in "${required_fns[@]}"; do
        assert_eq "${driver} has ${fn}" "true" \
            "$(type -t "$fn" >/dev/null 2>&1 && echo true || echo false)"
    done
}

# ============================================================
echo "=== 1. Driver files and interfaces ==="

for driver in claude-code fake gemini-cli codex-cli kimi-cli opencode droid; do
    assert_eq "${driver} file exists" "true" \
        "$([ -f "$DRIVERS_DIR/${driver}.sh" ] && echo true || echo false)"
    assert_driver_interface "$driver"
done
assert_eq "_common.sh exists" "true" \
    "$([ -f "$DRIVERS_DIR/_common.sh" ] && echo true || echo false)"

# ============================================================
echo ""
echo "=== 2. Shared helpers ==="

# shellcheck source=/dev/null
source "$DRIVERS_DIR/_common.sh"

cat > "$TMPDIR/common.jsonl" <<'EOF'
{"type":"system","subtype":"init","session_id":"s01","model":"claude-opus-4-6"}
{"type":"result","subtype":"success","session_id":"s01","total_cost_usd":0.42,"duration_ms":5000,"duration_api_ms":4000,"num_turns":3,"usage":{"input_tokens":200,"output_tokens":100,"cache_read_input_tokens":3000,"cache_creation_input_tokens":500}}
EOF

STATS=$(_extract_jsonl_stats "$TMPDIR/common.jsonl")
IFS=$'\t' read -r cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$STATS"
assert_eq "common cost" "0.42" "$cost"
assert_eq "common tok_in" "200" "$tok_in"
assert_eq "common tok_out" "100" "$tok_out"
assert_eq "common cache_rd" "3000" "$cache_rd"
assert_eq "common cache_cr" "500" "$cache_cr"
assert_eq "common dur" "5000" "$dur"
assert_eq "common api_ms" "4000" "$api_ms"
assert_eq "common turns" "3" "$turns"

W1="$TMPDIR/bridge-workspace-1"
mkdir -p "$W1/.claude" "$W1/.git/info"
echo "claude instructions" > "$W1/.claude/CLAUDE.md"
_bridge_agents_md "$W1"
assert_eq "bridge created AGENTS.md" "true" "$([ -f "$W1/AGENTS.md" ] && echo true || echo false)"
assert_eq "bridge copied Claude instructions" "claude instructions" "$(cat "$W1/AGENTS.md")"
assert_contains "bridge added exclude" "AGENTS.md" "$(cat "$W1/.git/info/exclude")"

W2="$TMPDIR/bridge-workspace-2"
mkdir -p "$W2/.git/info"
echo "root instructions" > "$W2/CLAUDE.md"
_bridge_agents_md "$W2"
assert_eq "bridge uses root CLAUDE.md" "root instructions" "$(cat "$W2/AGENTS.md")"

W3="$TMPDIR/bridge-workspace-3"
mkdir -p "$W3/.claude" "$W3/.git/info"
echo "existing" > "$W3/AGENTS.md"
echo "ignored" > "$W3/.claude/CLAUDE.md"
_bridge_agents_md "$W3"
assert_eq "existing AGENTS.md preserved" "existing" "$(cat "$W3/AGENTS.md")"

# ============================================================
echo ""
echo "=== 3. Driver metadata ==="

load_driver "claude-code"
assert_eq "claude name" "Claude Code" "$(agent_name)"
assert_eq "claude cmd" "claude" "$(agent_cmd)"
assert_eq "claude default model" "claude-opus-4-6" "$(agent_default_model)"
assert_contains "claude install script" "claude.ai" "$(agent_install_cmd)"

load_driver "fake"
assert_eq "fake name" "Fake Agent" "$(agent_name)"
assert_eq "fake cmd" "fake-agent" "$(agent_cmd)"
assert_eq "fake default model" "fake-model" "$(agent_default_model)"
assert_eq "fake version" "0.0.0-fake" "$(agent_version)"

load_driver "gemini-cli"
assert_eq "gemini name" "Gemini CLI" "$(agent_name)"
assert_eq "gemini cmd" "gemini" "$(agent_cmd)"
assert_eq "gemini default model" "gemini-2.5-pro" "$(agent_default_model)"
assert_contains "gemini install package" "@google/gemini-cli" "$(agent_install_cmd)"

load_driver "codex-cli"
assert_eq "codex name" "Codex CLI" "$(agent_name)"
assert_eq "codex cmd" "codex" "$(agent_cmd)"
assert_eq "codex default model" "gpt-5.4" "$(agent_default_model)"
assert_contains "codex install package" "@openai/codex" "$(agent_install_cmd)"

load_driver "kimi-cli"
assert_eq "kimi name" "Kimi CLI" "$(agent_name)"
assert_eq "kimi cmd" "kimi" "$(agent_cmd)"
assert_eq "kimi default model" "kimi-for-coding" "$(agent_default_model)"
assert_contains "kimi install script" "code.kimi.com/install.sh" "$(agent_install_cmd)"

load_driver "opencode"
assert_eq "opencode name" "OpenCode" "$(agent_name)"
assert_eq "opencode cmd" "opencode" "$(agent_cmd)"
assert_eq "opencode default model" "anthropic/claude-sonnet-4-5-20250929" "$(agent_default_model)"
assert_contains "opencode install package" "opencode-ai" "$(agent_install_cmd)"

load_driver "droid"
assert_eq "droid name" "Droid" "$(agent_name)"
assert_eq "droid cmd" "droid" "$(agent_cmd)"
assert_eq "droid default model" "glm-4.7" "$(agent_default_model)"
assert_contains "droid install package" "npm install -g droid" "$(agent_install_cmd)"

# ============================================================
echo ""
echo "=== 4. Activity filters across process boundary ==="

load_driver "claude-code"
agent_activity_jq > "$TMPDIR/claude.jq"
CLAUDE_INPUT='{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"Analyzing failure modes","signature":"sig"},{"type":"tool_use","name":"Read","input":{"file_path":"src/main.ts"}}]}}'
CLAUDE_OUT=$(render_with_filter "$TMPDIR/claude.jq" "$CLAUDE_INPUT")
assert_contains "claude filter shows thinking" "Think: Analyzing failure modes" "$CLAUDE_OUT"
assert_contains "claude filter shows read" "Read src/main.ts" "$CLAUDE_OUT"

load_driver "opencode"
agent_activity_jq > "$TMPDIR/opencode.jq"
OPENCODE_INPUT='{"type":"tool_call","toolName":"bash","parameters":{"command":"ls -la\npwd"}}'
OPENCODE_OUT=$(render_with_filter "$TMPDIR/opencode.jq" "$OPENCODE_INPUT")
assert_contains "opencode filter shows shell" "Shell: ls -la" "$OPENCODE_OUT"

load_driver "droid"
agent_activity_jq > "$TMPDIR/droid.jq"
DROID_INPUT='{"type":"tool_call","toolName":"Read","parameters":{"file_path":"README.md"}}'
DROID_OUT=$(render_with_filter "$TMPDIR/droid.jq" "$DROID_INPUT")
assert_contains "droid filter shows read" "Read README.md" "$DROID_OUT"

# ============================================================
echo ""
echo "=== 5. Claude Code driver ==="

load_driver "claude-code"

CC_WORK="$TMPDIR/claude-workspace"
mkdir -p "$CC_WORK"
agent_settings "$CC_WORK"
assert_eq "claude settings file created" "true" "$([ -f "$CC_WORK/.claude/settings.local.json" ] && echo true || echo false)"
assert_eq "claude settings valid JSON" "true" "$(jq empty "$CC_WORK/.claude/settings.local.json" >/dev/null 2>&1 && echo true || echo false)"
assert_eq "claude thinking summaries enabled" "true" "$(jq -r '.showThinkingSummaries' "$CC_WORK/.claude/settings.local.json")"

cat > "$TMPDIR/claude-stats.jsonl" <<'EOF'
{"type":"result","subtype":"success","session_id":"s01","total_cost_usd":0.1234,"duration_ms":15000,"duration_api_ms":12000,"num_turns":5,"usage":{"input_tokens":500,"output_tokens":300,"cache_read_input_tokens":8000,"cache_creation_input_tokens":1000}}
EOF
STATS=$(agent_extract_stats "$TMPDIR/claude-stats.jsonl")
IFS=$'\t' read -r cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$STATS"
assert_eq "claude cost" "0.1234" "$cost"
assert_eq "claude turns" "5" "$turns"

cat > "$TMPDIR/claude-fatal.jsonl" <<'EOF'
{"error":"model_not_found","message":"The model does not exist"}
{"type":"result","subtype":"error","session_id":"s01","total_cost_usd":0,"duration_ms":100,"duration_api_ms":0,"num_turns":0,"result":"Error","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}
EOF
FATAL=$(agent_detect_fatal "$TMPDIR/claude-fatal.jsonl" 1)
assert_contains "claude fatal mentions model_not_found" "model_not_found" "$FATAL"

cat > "$TMPDIR/claude-retry.jsonl" <<'EOF'
{"type":"rate_limit_event","rate_limit_info":{"status":"rejected"}}
EOF
assert_eq "claude retriable" "rate_limited" "$(agent_is_retriable "$TMPDIR/claude-retry.jsonl")"

assert_eq "claude validate anthropic oauth" "ok" \
    "$(agent_validate_config "claude-opus-4-6" "anthropic_oauth" "anthropic" "" "tok" "" "" "" "high" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "claude validate anthropic-compatible bearer" "ok" \
    "$(agent_validate_config "openai/gpt-5.4" "openrouter" "anthropic-compatible" "" "" "tok" "" "https://openrouter.ai/api" "" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "claude validate rejects auth_file" "fail" \
    "$(agent_validate_config "claude-opus-4-6" "anthropic_file" "anthropic" "" "" "" "$TMPDIR/auth.json" "" "" >/dev/null 2>&1 && echo ok || echo fail)"

AUTH=$(agent_docker_auth "anthropic_oauth" "anthropic" "" "tok" "" "" "")
assert_contains "claude docker auth oauth token" "CLAUDE_CODE_OAUTH_TOKEN=tok" "$AUTH"
assert_contains "claude docker auth oauth label" "SWARM_AUTH_MODE=oauth" "$AUTH"
AUTH=$(agent_docker_auth "anthropic_key" "anthropic" "sk-ant" "" "" "" "")
assert_contains "claude docker auth key" "ANTHROPIC_API_KEY=sk-ant" "$AUTH"
AUTH=$(agent_docker_auth "openrouter" "anthropic-compatible" "" "" "sk-or" "" "https://openrouter.ai/api")
assert_contains "claude docker auth bearer" "ANTHROPIC_AUTH_TOKEN=sk-or" "$AUTH"
assert_contains "claude docker auth base_url" "ANTHROPIC_BASE_URL=https://openrouter.ai/api" "$AUTH"
assert_contains "claude docker env effort" "CLAUDE_CODE_EFFORT_LEVEL=high" "$(agent_docker_env high)"

# ============================================================
echo ""
echo "=== 6. Fake driver ==="

load_driver "fake"

LOGFILE="$TMPDIR/fake.log"
agent_run "test-model" "test prompt" "$LOGFILE" >/dev/null
assert_eq "fake log created" "true" "$([ -s "$LOGFILE" ] && echo true || echo false)"
assert_eq "fake log line count" "3" "$(wc -l < "$LOGFILE" | tr -d ' ')"

STATS=$(agent_extract_stats "$LOGFILE")
IFS=$'\t' read -r cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$STATS"
assert_eq "fake stats cost" "0.0001" "$cost"
assert_eq "fake stats turns" "1" "$turns"
assert_eq "fake validate none" "ok" \
    "$(agent_validate_config "fake-model" "none" "none" "" "" "" "" "" "" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "fake validate rejects key" "fail" \
    "$(agent_validate_config "fake-model" "none" "none" "sk" "" "" "" "" "" >/dev/null 2>&1 && echo ok || echo fail)"
assert_contains "fake docker auth mode" "SWARM_AUTH_MODE=none" "$(agent_docker_auth)"

# ============================================================
echo ""
echo "=== 7. Gemini CLI driver ==="

load_driver "gemini-cli"

G_WORK="$TMPDIR/gemini-workspace"
mkdir -p "$G_WORK"
agent_settings "$G_WORK"
assert_eq "gemini settings file created" "true" "$([ -f "$G_WORK/.gemini/settings.json" ] && echo true || echo false)"
assert_eq "gemini settings valid JSON" "true" "$(jq empty "$G_WORK/.gemini/settings.json" >/dev/null 2>&1 && echo true || echo false)"

cat > "$TMPDIR/gemini-stats.jsonl" <<'EOF'
{"type":"result","stats":{"input_tokens":800,"output_tokens":200,"cached":5000,"duration_ms":12000,"tool_calls":4}}
EOF
STATS=$(agent_extract_stats "$TMPDIR/gemini-stats.jsonl")
IFS=$'\t' read -r cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$STATS"
assert_eq "gemini stats input" "800" "$tok_in"
assert_eq "gemini stats cached" "5000" "$cache_rd"
assert_eq "gemini stats turns" "4" "$turns"

cat > "$TMPDIR/gemini-fatal.jsonl" <<'EOF'
{"type":"result","status":"error","error":{"message":"[API Error: Invalid API key]"},"stats":{"input_tokens":0,"output_tokens":0}}
EOF
GFATAL=$(agent_detect_fatal "$TMPDIR/gemini-fatal.jsonl")
assert_contains "gemini fatal message" "Invalid API key" "$GFATAL"

cat > "$TMPDIR/gemini-rate.err" <<'EOF'
RESOURCE_EXHAUSTED: retry in 60s
EOF
assert_eq "gemini retriable" "rate_limited" "$(agent_is_retriable "$TMPDIR/gemini-rate")"

assert_eq "gemini validate key" "ok" \
    "$(agent_validate_config "gemini-2.5-pro" "gemini_key" "gemini" "sk-gem" "" "" "" "" "" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "gemini validate rejects base_url" "fail" \
    "$(agent_validate_config "gemini-2.5-pro" "gemini_key" "gemini" "sk-gem" "" "" "" "https://x" "" >/dev/null 2>&1 && echo ok || echo fail)"
assert_contains "gemini docker auth key" "GEMINI_API_KEY=sk-gem" "$(agent_docker_auth "gemini_key" "gemini" "sk-gem" "" "" "" "")"

# ============================================================
echo ""
echo "=== 8. Codex CLI driver ==="

load_driver "codex-cli"

C_HOME="$TMPDIR/codex-home"
C_WORK="$TMPDIR/codex-workspace"
mkdir -p "$C_HOME" "$C_WORK/.claude/skills" "$C_WORK/.git/info"
echo "project rules" > "$C_WORK/.claude/CLAUDE.md"
(
    export HOME="$C_HOME"
    agent_settings "$C_WORK"
)
assert_eq "codex config.toml created" "true" "$([ -f "$C_HOME/.codex/config.toml" ] && echo true || echo false)"
assert_eq "codex AGENTS.md bridged" "project rules" "$(cat "$C_WORK/AGENTS.md")"
assert_eq "codex skills symlink created" "true" "$([ -L "$C_WORK/.agents/skills" ] && echo true || echo false)"
assert_contains "codex exclude has .agents" ".agents/" "$(cat "$C_WORK/.git/info/exclude")"

cat > "$TMPDIR/codex-stats.jsonl" <<'EOF'
{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":50}}
{"type":"turn.completed","usage":{"input_tokens":60,"cached_input_tokens":10,"output_tokens":30}}
EOF
STATS=$(agent_extract_stats "$TMPDIR/codex-stats.jsonl")
IFS=$'\t' read -r cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$STATS"
assert_eq "codex stats input excludes cached" "130" "$tok_in"
assert_eq "codex stats output" "80" "$tok_out"
assert_eq "codex stats cached" "30" "$cache_rd"
assert_eq "codex stats turns" "2" "$turns"

cat > "$TMPDIR/codex-fatal.jsonl" <<'EOF'
{"type":"turn.failed","error":"authentication_error"}
EOF
CFATAL=$(agent_detect_fatal "$TMPDIR/codex-fatal.jsonl")
assert_contains "codex fatal auth" "authentication_error" "$CFATAL"

cat > "$TMPDIR/codex-rate.err" <<'EOF'
429 Too many requests
EOF
assert_eq "codex retriable" "rate_limited" "$(agent_is_retriable "$TMPDIR/codex-rate")"

AUTH_FILE="$TMPDIR/codex-auth.json"
echo '{"tokens":{"access":"test"}}' > "$AUTH_FILE"
assert_eq "codex validate api_key" "ok" \
    "$(agent_validate_config "gpt-5.4" "openai_key" "openai" "sk-openai" "" "" "" "" "" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "codex validate auth_file" "ok" \
    "$(agent_validate_config "gpt-5.4" "openai_file" "openai" "" "" "" "$AUTH_FILE" "" "" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "codex validate rejects wrong kind" "fail" \
    "$(agent_validate_config "gpt-5.4" "anthropic_key" "anthropic" "sk-openai" "" "" "" "" "" >/dev/null 2>&1 && echo ok || echo fail)"
assert_contains "codex docker auth key" "OPENAI_API_KEY=sk-openai" "$(agent_docker_auth "openai_key" "openai" "sk-openai" "" "" "" "")"
AUTH=$(agent_docker_auth "openai_file" "openai" "" "" "" "$AUTH_FILE" "")
assert_contains "codex docker auth mount" "$AUTH_FILE" "$AUTH"
assert_contains "codex docker auth file label" "SWARM_AUTH_MODE=file" "$AUTH"
assert_contains "codex docker env effort" "CODEX_EFFORT=high" "$(agent_docker_env high)"

# ============================================================
echo ""
echo "=== 9. Kimi CLI driver ==="

load_driver "kimi-cli"

K_HOME="$TMPDIR/kimi-home"
K_WORK="$TMPDIR/kimi-workspace"
mkdir -p "$K_HOME" "$K_WORK/.claude" "$K_WORK/.git/info"
echo "kimi instructions" > "$K_WORK/.claude/CLAUDE.md"
(
    export HOME="$K_HOME"
    agent_settings "$K_WORK"
)
assert_eq "kimi bridge AGENTS.md" "kimi instructions" "$(cat "$K_WORK/AGENTS.md")"

cat > "$TMPDIR/kimi-stats.jsonl" <<'EOF'
{"role":"assistant","content":"A"}
{"role":"assistant","content":"B"}
EOF
STATS=$(agent_extract_stats "$TMPDIR/kimi-stats.jsonl")
IFS=$'\t' read -r cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$STATS"
assert_eq "kimi turns from assistant events" "2" "$turns"

cat > "$TMPDIR/kimi-fatal.err" <<'EOF'
Invalid API key
EOF
KFATAL=$(agent_detect_fatal "$TMPDIR/kimi-fatal" 1)
assert_contains "kimi fatal invalid key" "Invalid API key" "$KFATAL"
assert_eq "kimi retriable exit 75" "transient_error" "$(agent_is_retriable "$TMPDIR/kimi-any" 75)"
assert_eq "kimi validate key" "ok" \
    "$(agent_validate_config "kimi-for-coding" "kimi_key" "kimi" "sk-kimi" "" "" "" "https://api.kimi.com/coding/v1" "off" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "kimi validate rejects oauth" "fail" \
    "$(agent_validate_config "kimi-for-coding" "kimi_key" "kimi" "" "tok" "" "" "" "" >/dev/null 2>&1 && echo ok || echo fail)"
assert_contains "kimi docker env disable update" "KIMI_CLI_NO_AUTO_UPDATE=1" "$(agent_docker_env high)"
KAUTH=$(agent_docker_auth "kimi_key" "kimi" "sk-kimi" "" "" "" "")
assert_contains "kimi docker auth key" "SWARM_KIMI_API_KEY=sk-kimi" "$KAUTH"
assert_contains "kimi docker auth default base_url" "SWARM_KIMI_BASE_URL=https://api.kimi.com/coding/v1" "$KAUTH"

# ============================================================
echo ""
echo "=== 10. OpenCode driver ==="

load_driver "opencode"

assert_eq "opencode validate anthropic oauth" "ok" \
    "$(agent_validate_config "anthropic/claude-sonnet-4-5-20250929" "anthropic" "anthropic" "" "tok" "" "" "" "high" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "opencode validate openai-compatible auth_file" "ok" \
    "$(agent_validate_config "proxy/gpt-5.4" "proxy" "openai-compatible" "" "" "" "$AUTH_FILE" "https://api.example.com/v1" "" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "opencode validate rejects bad prefix" "fail" \
    "$(agent_validate_config "openai/gpt-5.4" "proxy" "openai-compatible" "sk" "" "" "" "https://api.example.com/v1" "" >/dev/null 2>&1 && echo ok || echo fail)"

OC_HOME="$TMPDIR/opencode-home"
OC_WORK="$TMPDIR/opencode-workspace"
mkdir -p "$OC_HOME" "$OC_WORK"
(
    export HOME="$OC_HOME"
    export SWARM_PROVIDER_NAME="anthropic"
    export SWARM_PROVIDER_KIND="anthropic"
    export SWARM_MODEL="anthropic/claude-sonnet-4-5-20250929"
    export SWARM_PROVIDER_OAUTH_TOKEN="tok-oauth"
    export SWARM_PROVIDER_API_KEY=""
    export SWARM_PROVIDER_BEARER_TOKEN=""
    export SWARM_PROVIDER_BASE_URL=""
    agent_settings "$OC_WORK"
)
assert_eq "opencode auth.json synthesized" "true" "$([ -f "$OC_HOME/.local/share/opencode/auth.json" ] && echo true || echo false)"
assert_eq "opencode oauth auth type" "oauth" "$(jq -r '.anthropic.type' "$OC_HOME/.local/share/opencode/auth.json")"
assert_eq "opencode oauth access token" "tok-oauth" "$(jq -r '.anthropic.access' "$OC_HOME/.local/share/opencode/auth.json")"
assert_eq "opencode config model" "anthropic/claude-sonnet-4-5-20250929" "$(jq -r '.model' "$OC_HOME/.config/opencode/opencode.json")"

OC_HOME2="$TMPDIR/opencode-home-2"
mkdir -p "$OC_HOME2"
(
    export HOME="$OC_HOME2"
    export SWARM_PROVIDER_NAME="proxy"
    export SWARM_PROVIDER_KIND="openai-compatible"
    export SWARM_MODEL="proxy/gpt-5.4"
    export SWARM_PROVIDER_API_KEY="sk-openai"
    export SWARM_PROVIDER_OAUTH_TOKEN=""
    export SWARM_PROVIDER_BEARER_TOKEN=""
    export SWARM_PROVIDER_BASE_URL="https://api.example.com/v1"
    export SWARM_PROVIDER_AUTH_FILE_CONTAINER=""
    agent_settings "$OC_WORK"
)
assert_eq "opencode proxy npm package" "@ai-sdk/openai-compatible" "$(jq -r '.provider.proxy.npm' "$OC_HOME2/.config/opencode/opencode.json")"
assert_eq "opencode proxy baseURL" "https://api.example.com/v1" "$(jq -r '.provider.proxy.options.baseURL' "$OC_HOME2/.config/opencode/opencode.json")"
assert_eq "opencode proxy apiKey" "sk-openai" "$(jq -r '.provider.proxy.options.apiKey' "$OC_HOME2/.config/opencode/opencode.json")"
assert_eq "opencode proxy model alias" "{}" "$(jq -c '.provider.proxy.models["gpt-5.4"]' "$OC_HOME2/.config/opencode/opencode.json")"

MOUNTED_AUTH="$TMPDIR/opencode-mounted-auth.json"
echo '{"openai":{"type":"api","key":"sk-from-file"}}' > "$MOUNTED_AUTH"
OC_HOME3="$TMPDIR/opencode-home-3"
mkdir -p "$OC_HOME3"
(
    export HOME="$OC_HOME3"
    export SWARM_PROVIDER_NAME="openai"
    export SWARM_PROVIDER_KIND="openai"
    export SWARM_MODEL="openai/gpt-5.4"
    export SWARM_PROVIDER_API_KEY=""
    export SWARM_PROVIDER_OAUTH_TOKEN=""
    export SWARM_PROVIDER_BEARER_TOKEN=""
    export SWARM_PROVIDER_BASE_URL=""
    export SWARM_PROVIDER_AUTH_FILE_CONTAINER="$MOUNTED_AUTH"
    agent_settings "$OC_WORK"
)
assert_eq "opencode copied mounted auth file" '{"openai":{"type":"api","key":"sk-from-file"}}' "$(tr -d '\n' < "$OC_HOME3/.local/share/opencode/auth.json")"

cat > "$TMPDIR/opencode-stats.jsonl" <<'EOF'
{"role":"assistant","usage":{"input_tokens":120,"output_tokens":45,"cache_read_input_tokens":30},"duration_ms":3210}
EOF
STATS=$(agent_extract_stats "$TMPDIR/opencode-stats.jsonl")
IFS=$'\t' read -r cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$STATS"
assert_eq "opencode stats input" "120" "$tok_in"
assert_eq "opencode stats output" "45" "$tok_out"
assert_eq "opencode stats cached" "30" "$cache_rd"
assert_eq "opencode stats turns" "1" "$turns"

cat > "$TMPDIR/opencode-fatal.err" <<'EOF'
error: invalid API key
EOF
OFATAL=$(agent_detect_fatal "$TMPDIR/opencode-fatal" 1)
assert_contains "opencode fatal invalid key" "invalid API key" "$OFATAL"
cat > "$TMPDIR/opencode-rate.err" <<'EOF'
429 too many requests
EOF
assert_eq "opencode retriable" "transient_error" "$(agent_is_retriable "$TMPDIR/opencode-rate")"

assert_contains "opencode docker env disable update" "OPENCODE_DISABLE_AUTOUPDATE=1" "$(agent_docker_env high)"
AUTH=$(agent_docker_auth "openai_file" "openai" "" "" "" "$AUTH_FILE" "")
assert_contains "opencode docker auth mount" "$AUTH_FILE" "$AUTH"
assert_contains "opencode docker auth file label" "SWARM_AUTH_MODE=file" "$AUTH"
assert_contains "opencode docker auth container path" "SWARM_PROVIDER_AUTH_FILE_CONTAINER=/tmp/swarm/opencode-provider-auth.json" "$AUTH"
assert_contains "opencode docker auth oauth label" "SWARM_AUTH_MODE=oauth" "$(agent_docker_auth "anthropic" "anthropic" "" "tok" "" "" "")"
assert_contains "opencode docker auth token label" "SWARM_AUTH_MODE=token" "$(agent_docker_auth "proxy" "openai-compatible" "" "" "tok" "" "https://api.example.com/v1")"
assert_contains "opencode docker auth key label" "SWARM_AUTH_MODE=key" "$(agent_docker_auth "openai" "openai" "sk" "" "" "" "")"

# ============================================================
echo ""
echo "=== 11. Droid driver ==="

load_driver "droid"

D_HOME="$TMPDIR/droid-home"
D_WORK="$TMPDIR/droid-workspace"
mkdir -p "$D_HOME" "$D_WORK/.claude" "$D_WORK/.git/info"
echo "droid instructions" > "$D_WORK/.claude/CLAUDE.md"
(
    export HOME="$D_HOME"
    export SWARM_EFFORT="medium"
    agent_settings "$D_WORK"
)
assert_eq "droid settings.local.json created" "true" "$([ -f "$D_HOME/.factory/settings.local.json" ] && echo true || echo false)"
assert_eq "droid reasoningEffort" "medium" "$(jq -r '.reasoningEffort' "$D_HOME/.factory/settings.local.json")"
assert_eq "droid AGENTS.md bridged" "droid instructions" "$(cat "$D_WORK/AGENTS.md")"

cat > "$TMPDIR/droid-stats.jsonl" <<'EOF'
{"type":"completion","durationMs":4567,"numTurns":3}
EOF
STATS=$(agent_extract_stats "$TMPDIR/droid-stats.jsonl")
IFS=$'\t' read -r cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$STATS"
assert_eq "droid duration" "4567" "$dur"
assert_eq "droid turns" "3" "$turns"

cat > "$TMPDIR/droid-fatal.err" <<'EOF'
Permission denied
EOF
DFATAL=$(agent_detect_fatal "$TMPDIR/droid-fatal" 1)
assert_contains "droid fatal permission" "Permission denied" "$DFATAL"
cat > "$TMPDIR/droid-rate.err" <<'EOF'
429 rate limit exceeded
EOF
assert_eq "droid retriable" "transient_error" "$(agent_is_retriable "$TMPDIR/droid-rate")"

assert_eq "droid validate key" "ok" \
    "$(agent_validate_config "glm-4.7" "factory_key" "factory" "sk-factory" "" "" "" "" "medium" >/dev/null 2>&1 && echo ok || echo fail)"
assert_eq "droid validate rejects openai" "fail" \
    "$(agent_validate_config "glm-4.7" "openai_key" "openai" "sk-openai" "" "" "" "" "" >/dev/null 2>&1 && echo ok || echo fail)"
DAUTH=$(agent_docker_auth "factory_key" "factory" "sk-factory" "" "" "" "")
assert_contains "droid docker auth key" "FACTORY_API_KEY=sk-factory" "$DAUTH"
assert_contains "droid docker auth label" "SWARM_AUTH_MODE=key" "$DAUTH"

# ============================================================
echo ""
echo "=== 43. _common.sh — process group reaper (_run_reaped) ==="

# Agent CLIs commonly spawn helper children (MCP servers, reasoning
# workers, IPC brokers) that inherit stdout. When the CLI's main
# process exits without waiting, those children hold the pipe to
# the downstream activity-filter, which wedges the harness until
# the container is externally killed. _run_reaped puts each CLI in
# its own process group so the harness can SIGKILL the group after
# the main process exits, releasing surviving descendants' FDs.

source "$DRIVERS_DIR/_common.sh"

# --- Structural: helper is defined and callable.
assert_eq "_run_reaped is defined" "function" \
    "$(type -t _run_reaped || echo missing)"

# --- Structural: real-CLI drivers call the helper, and the bare
# `| stdbuf -oL tee "$logfile"` form is absent. Pin both per
# driver. fake.sh is intentionally exempt -- it emits synthetic
# JSONL inline and never spawns external children.
for _drv in claude-code codex-cli gemini-cli kimi-cli opencode droid; do
    assert_eq "$_drv: adopts _run_reaped" "1" \
        "$(grep -cE '^[[:space:]]*_run_reaped "\$logfile"' "$DRIVERS_DIR/$_drv.sh")"
    assert_eq "$_drv: drops bare tee pipe" "0" \
        "$(grep -cE 'stdbuf -oL tee "\$logfile"' "$DRIVERS_DIR/$_drv.sh" || true)"
done

# --- Behavioral tests below require `setsid` and `stdbuf` on the
# host (both GNU utilities).  Stock macOS ships neither, so skip
# these assertions when they're missing -- the structural pins
# above are what prevent the bug from silently regressing; the
# behavioural tests just provide end-to-end confidence on Linux CI.
if ! command -v setsid >/dev/null 2>&1 \
        || ! command -v stdbuf >/dev/null 2>&1; then
    echo "  SKIP: reaper behavioural tests (setsid/stdbuf unavailable)"
else
    # --- Behavioral: fake CLI that forks a surviving child and exits.
    # Without reaping, the child's stdout FD would keep the pipeline
    # blocked. With reaping, the pipeline drains immediately and the
    # CLI's exit code is propagated.  Sleep duration is deliberately
    # oddball so the cleanup pkill can match it unambiguously.
    cat > "$TMPDIR/reap_cli.sh" <<'CLI'
#!/bin/bash
echo "$2"
( sleep 31337 ) &
exit "${1:-0}"
CLI
    chmod +x "$TMPDIR/reap_cli.sh"

    # Exit-0 path: pipeline drains, stdout tee'd, exit code preserved.
    _reap_start=$(date +%s)
    _run_reaped "$TMPDIR/reap_zero.log" "$TMPDIR/reap_cli.sh" 0 "hello from CLI"
    _reap_ec=$?
    _reap_elapsed=$(($(date +%s) - _reap_start))

    assert_eq "reaped run: exit code preserved (0)" "0" "$_reap_ec"
    assert_eq "reaped run: stdout captured in logfile" "hello from CLI" \
        "$(cat "$TMPDIR/reap_zero.log")"
    # Generous bound for slow CI; actual drain is ~10-50ms, but
    # shared runners can occasionally delay process scheduling.
    assert_eq "reaped run: drains despite surviving child" "true" \
        "$([ "$_reap_elapsed" -lt 10 ] && echo true || echo false)"

    # Non-zero exit path: exit code is likewise propagated.
    # `|| _reap_ec=$?` keeps set -e from aborting the test script.
    _reap_ec=0
    _run_reaped "$TMPDIR/reap_nz.log" "$TMPDIR/reap_cli.sh" 42 "boom" \
        || _reap_ec=$?
    assert_eq "reaped run: non-zero exit preserved (42)" "42" "$_reap_ec"

    # --- Defensive cleanup: if the kill-group regressed, sweep any
    # orphan `sleep 31337` so CI doesn't leak processes.
    pkill -f 'sleep 31337' 2>/dev/null || true
fi

# ============================================================
echo ""
echo "=== 40. _common.sh — activity watchdog (_reap_watchdog) ==="

# _run_reaped's process-group kill only fires *after* wait returns.
# When the CLI itself is alive but deadlocked (stuck model request,
# blocked MCP tool, infinite I/O wait) the wait never returns and
# the group kill never runs -- empirically observed as "silence for
# 4h22m until external docker stop" on codex-cli swarms.
#
# 0.20.5 adds _reap_watchdog: a sibling background process that
# polls the logfile's mtime every 10s.  If SWARM_ACTIVITY_TIMEOUT
# is a positive integer and the logfile hasn't advanced in that
# many seconds, SIGTERM the CLI's process group (10s grace, then
# SIGKILL).  Opt-in via SWARM_ACTIVITY_TIMEOUT so operators who
# haven't observed the hang don't get surprise kills.
#
# §40a pins the structural invariants of the watchdog and its
# integration with _run_reaped.  §40b rehearses the full
# start-timeout-kill sequence against a synthetic deadlocked CLI
# so the watchdog's end-to-end effect is exercised too.

COMMON_FILE="$DRIVERS_DIR/_common.sh"

# --- §40a. Structural pins against lib/drivers/_common.sh.

assert_eq "watchdog function is defined" "1" \
    "$(grep -cE '^_reap_watchdog\(\) \{' "$COMMON_FILE")"

# Polling interval is configurable via SWARM_ACTIVITY_POLL; the
# default of 10s is short enough to react, long enough to stay
# invisible on a chatty CLI.  Tests set it to 1s to keep the
# behavioural suite under a few seconds.
assert_eq "watchdog reads SWARM_ACTIVITY_POLL knob" "1" \
    "$(grep -cE 'SWARM_ACTIVITY_POLL:-10' "$COMMON_FILE")"
assert_eq "watchdog sleeps for the configured poll interval" "1" \
    "$(grep -cE 'sleep "\$_poll"' "$COMMON_FILE")"

# Same pattern for the SIGTERM -> SIGKILL grace window.  Exposing
# it (vs hardcoding 10s) matters for tests, which exercise the
# full escalation in ~2s.
assert_eq "watchdog reads SWARM_WATCHDOG_GRACE knob" "1" \
    "$(grep -cE 'SWARM_WATCHDOG_GRACE:-10' "$COMMON_FILE")"

# Post-SIGTERM: poll-and-exit-early rather than a fixed sleep,
# so a process that honoured SIGTERM doesn't force the whole
# harness to wait out the grace window.
assert_eq "watchdog polls for SIGTERM effect rather than fixed sleep" "1" \
    "$(grep -cE 'for _i in \$\(seq 1 "\$_grace"\); do' "$COMMON_FILE")"

# mtime probe uses GNU stat first (-c %Y) with a BSD fallback
# (-f %m), so the helper is exercised the same way on macOS CI
# and on the Linux production container.  Three hits each: the
# preamble comment, the _last_mtime seed, and the per-poll read.
assert_eq "watchdog uses GNU stat -c %Y (preamble + seed + poll)" "3" \
    "$(grep -cE 'stat -c %Y' "$COMMON_FILE")"
assert_eq "watchdog falls back to BSD stat -f %m (preamble + seed + poll)" "3" \
    "$(grep -cE 'stat -f %m' "$COMMON_FILE")"

# SIGTERM-then-SIGKILL escalation.  _run_reaped contributes its
# own `kill -KILL` after wait (the §39 group kill), so the -KILL
# count here is 2 -- both are essential and dropping either
# regresses a fix.
assert_eq "watchdog escalates with SIGTERM first" "1" \
    "$(grep -cE 'kill -TERM -- "-\$_cmd_pid"' "$COMMON_FILE")"
assert_eq "both watchdog and _run_reaped group-SIGKILL on failure" "2" \
    "$(grep -cE 'kill -KILL -- "-\$_cmd_pid"' "$COMMON_FILE")"

# _run_reaped must gate on SWARM_ACTIVITY_TIMEOUT (opt-in knob);
# any value that isn't a strict positive integer disables it.
assert_eq "_run_reaped reads SWARM_ACTIVITY_TIMEOUT" "1" \
    "$(grep -cE 'SWARM_ACTIVITY_TIMEOUT:-0' "$COMMON_FILE")"
assert_eq "_run_reaped validates timeout as integer" "1" \
    "$(grep -cE '\[\[ "\$_wd_timeout" =~ \^\[0-9\]\+\$ \]\]' "$COMMON_FILE")"

# Watchdog is spawned in the background alongside the CLI with
# its diagnostics tee'd into the CLI's stderr file so callers
# that redirected their own stderr still get the kill record.
# The `&` terminator lives on its own line; pin the invocation
# and the stderr redirect independently.
assert_eq "_run_reaped invokes _reap_watchdog with the trio" "1" \
    "$(grep -cE '_reap_watchdog "\$logfile" "\$_cmd_pid" "\$_wd_timeout"' "$COMMON_FILE")"
assert_eq "_run_reaped tees watchdog stderr next to CLI stderr" "1" \
    "$(grep -cE '2>>"\$\{logfile\}\.err" &' "$COMMON_FILE")"
assert_eq "_run_reaped kills watchdog after wait" "1" \
    "$(grep -cE 'kill "\$_wd_pid" 2>/dev/null' "$COMMON_FILE")"
assert_eq "_run_reaped reaps watchdog after kill" "1" \
    "$(grep -cE 'wait "\$_wd_pid" 2>/dev/null' "$COMMON_FILE")"

# --- §40b. Behavioral: a deadlocked CLI is force-killed by the
# watchdog within the configured timeout window.
#
# Skips on hosts without setsid/stdbuf -- the structural pins
# above are the main regression guard; the behavioural test just
# provides live coverage on Linux CI.  We drive the watchdog at
# SWARM_ACTIVITY_POLL=1, SWARM_WATCHDOG_GRACE=1 so the full
# escalation completes in ~3s and the test adds ~5s to the suite.

# Small helper to count matches without tripping assert_eq with
# grep's noisy `0 + exit 1 + || echo 0` behaviour (which was
# double-counting zeros in an earlier iteration).
_wd_count() {
    local _pat="$1" _file="$2"
    if [ ! -f "$_file" ]; then echo 0; return; fi
    grep -cE "$_pat" "$_file" 2>/dev/null || true
}

if ! command -v setsid >/dev/null 2>&1 \
        || ! command -v stdbuf >/dev/null 2>&1; then
    echo "  SKIP: watchdog behavioural test (setsid/stdbuf unavailable)"
else
    # Synthetic CLI: emits one line, then sleeps indefinitely.
    # The log mtime will freeze after the initial write and the
    # watchdog must then escalate.  Sleep duration is oddball for
    # unambiguous cleanup matching.
    cat > "$TMPDIR/wd_cli.sh" <<'CLI'
#!/bin/bash
echo "alive"
sleep 98765
CLI
    chmod +x "$TMPDIR/wd_cli.sh"

    # Drive the full watchdog escalation:
    #   POLL=1 grace=1 timeout=2 → first poll at t=1s (initial
    #   "alive" write advances _last_mtime), second poll at t=2s
    #   (mtime stale for ≥2s → SIGTERM → the bash default handler
    #   exits → the grace loop returns early).  End-to-end ~2-3s.
    _wd_start=$(date +%s)
    SWARM_ACTIVITY_TIMEOUT=2 \
    SWARM_ACTIVITY_POLL=1 \
    SWARM_WATCHDOG_GRACE=1 \
        _run_reaped "$TMPDIR/wd_run.log" "$TMPDIR/wd_cli.sh" \
        >/dev/null 2>&1 || true
    _wd_elapsed=$(($(date +%s) - _wd_start))

    assert_eq "watchdog terminates deadlocked CLI within budget" \
        "true" \
        "$([ "$_wd_elapsed" -lt 10 ] && echo true || echo false)"

    # The watchdog's diagnostic line lands on stderr, which
    # _run_reaped redirects to <logfile>.err.  Its presence is
    # proof the watchdog actually fired (rather than the CLI
    # exiting spontaneously for some unrelated reason).
    assert_eq "watchdog logs its own kill decision" "1" \
        "$(_wd_count '\[swarm watchdog\] no log activity' \
            "$TMPDIR/wd_run.log.err")"

    # Sanity: the CLI's initial "alive" line did make it through
    # the tee pipe before the watchdog fired.
    assert_eq "pre-kill output still tee'd to logfile" "alive" \
        "$(head -1 "$TMPDIR/wd_run.log" 2>/dev/null)"

    # --- Watchdog must stay dormant when the knob is unset or
    # non-numeric.  Run a short well-behaved CLI and verify no
    # watchdog diagnostics leak and elapsed stays near the CLI's
    # own runtime rather than inflating to the grace window.
    cat > "$TMPDIR/wd_quick.sh" <<'CLI'
#!/bin/bash
echo "done"
exit 0
CLI
    chmod +x "$TMPDIR/wd_quick.sh"

    unset SWARM_ACTIVITY_TIMEOUT SWARM_ACTIVITY_POLL SWARM_WATCHDOG_GRACE
    _wd_start=$(date +%s)
    _run_reaped "$TMPDIR/wd_quick.log" "$TMPDIR/wd_quick.sh" \
        >/dev/null 2>&1 || true
    _wd_elapsed=$(($(date +%s) - _wd_start))
    assert_eq "unset timeout: watchdog stays dormant" "true" \
        "$([ "$_wd_elapsed" -lt 3 ] && echo true || echo false)"
    assert_eq "unset timeout: no watchdog diagnostics" "0" \
        "$(_wd_count 'swarm watchdog' "$TMPDIR/wd_quick.log.err")"

    # Non-integer value must degrade to disabled, not crash.
    SWARM_ACTIVITY_TIMEOUT="nonsense" \
        _run_reaped "$TMPDIR/wd_bad.log" "$TMPDIR/wd_quick.sh" \
        >/dev/null 2>&1 || true
    assert_eq "non-integer timeout: no watchdog diagnostics" "0" \
        "$(_wd_count 'swarm watchdog' "$TMPDIR/wd_bad.log.err")"

    # Defensive cleanup: any leaked `sleep 98765` from a regression
    # must not survive the test.
    pkill -f 'sleep 98765' 2>/dev/null || true
fi

echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
