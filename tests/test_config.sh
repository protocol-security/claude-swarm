#!/bin/bash
# shellcheck disable=SC2034
set -euo pipefail

# Unit tests for swarm.json config parsing under the v2 provider schema.
# No Docker or API keys required.

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

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

parse_prompt() { jq -r '.prompt // empty' "$1"; }
parse_setup() { jq -r '.setup // empty' "$1"; }
parse_max_idle() { jq -r '.max_idle // 3' "$1"; }
parse_git_name() { jq -r '.git_user.name // "swarm-agent"' "$1"; }
parse_git_email() { jq -r '.git_user.email // "agent@swarm.local"' "$1"; }
parse_signing_key() { jq -r '.git_user.signing_key // empty' "$1"; }
parse_num_agents() { jq '[.agents[].count] | add' "$1"; }
parse_inject_git_rules() { jq -r 'if has("inject_git_rules") then .inject_git_rules else true end' "$1"; }
parse_title() { jq -r '.title // empty' "$1"; }
parse_pp_prompt() { jq -r '.post_process.prompt // empty' "$1"; }
parse_pp_model() { jq -r '.post_process.model // "claude-opus-4-6"' "$1"; }
parse_pp_provider() { jq -r '.post_process.provider // empty' "$1"; }
parse_pp_max_idle() { jq -r '.post_process.max_idle // .max_idle // 3' "$1"; }

parse_agents_cfg() {
    jq -r '
        .tag as $dt | .driver as $dd | .agents[] | range(.count) as $i |
        [.model, (.provider // ""), (.effort // ""), (.context // ""), (.prompt // ""), (.tag // $dt // ""), (.driver // $dd // "")] | join("|")
    ' "$1"
}

has_legacy_auth_fields() {
    jq -e '
        def legacy:
            has("auth") or has("api_key") or has("auth_token") or has("base_url");
        ([.agents[]? | legacy] | any) or ((.post_process? // {}) | legacy)
    ' "$1" >/dev/null 2>&1
}

# ============================================================
echo "=== 1. Synthetic v2 config parsing ==="

cat > "$TMPDIR/synthetic.json" <<'EOF'
{
  "prompt": "prompts/task.md",
  "setup": "scripts/setup.sh",
  "max_idle": 5,
  "inject_git_rules": false,
  "title": "Provider Test",
  "driver": "claude-code",
  "tag": "top-tag",
  "git_user": {
    "name": "test-agent",
    "email": "test@example.com",
    "signing_key": "$SIGNING_KEY"
  },
  "providers": {
    "anthropic_oauth": {
      "kind": "anthropic",
      "oauth_token": "$CLAUDE_CODE_OAUTH_TOKEN"
    },
    "openrouter": {
      "kind": "anthropic-compatible",
      "base_url": "https://openrouter.ai/api",
      "bearer_token": "$OPENROUTER_API_KEY"
    }
  },
  "agents": [
    {
      "count": 2,
      "model": "claude-opus-4-6",
      "provider": "anthropic_oauth",
      "effort": "high"
    },
    {
      "count": 1,
      "model": "openai/gpt-5.4",
      "provider": "openrouter",
      "context": "slim",
      "prompt": "prompts/review.md",
      "tag": "review",
      "driver": "claude-code"
    }
  ],
  "post_process": {
    "prompt": "prompts/post.md",
    "model": "claude-sonnet-4-6",
    "provider": "anthropic_oauth",
    "max_idle": 2
  }
}
EOF

assert_eq "prompt" "prompts/task.md" "$(parse_prompt "$TMPDIR/synthetic.json")"
assert_eq "setup" "scripts/setup.sh" "$(parse_setup "$TMPDIR/synthetic.json")"
assert_eq "max_idle" "5" "$(parse_max_idle "$TMPDIR/synthetic.json")"
assert_eq "inject_git_rules" "false" "$(parse_inject_git_rules "$TMPDIR/synthetic.json")"
assert_eq "title" "Provider Test" "$(parse_title "$TMPDIR/synthetic.json")"
assert_eq "git name" "test-agent" "$(parse_git_name "$TMPDIR/synthetic.json")"
assert_eq "git email" "test@example.com" "$(parse_git_email "$TMPDIR/synthetic.json")"
assert_eq "signing key" '$SIGNING_KEY' "$(parse_signing_key "$TMPDIR/synthetic.json")"
assert_eq "num agents" "3" "$(parse_num_agents "$TMPDIR/synthetic.json")"
assert_eq "pp prompt" "prompts/post.md" "$(parse_pp_prompt "$TMPDIR/synthetic.json")"
assert_eq "pp model" "claude-sonnet-4-6" "$(parse_pp_model "$TMPDIR/synthetic.json")"
assert_eq "pp provider" "anthropic_oauth" "$(parse_pp_provider "$TMPDIR/synthetic.json")"
assert_eq "pp max_idle" "2" "$(parse_pp_max_idle "$TMPDIR/synthetic.json")"

CFG=$(parse_agents_cfg "$TMPDIR/synthetic.json")
assert_eq "agents cfg line count" "3" "$(echo "$CFG" | wc -l | tr -d ' ')"

LINE1=$(echo "$CFG" | sed -n '1p')
LINE3=$(echo "$CFG" | sed -n '3p')
IFS='|' read -r model1 provider1 effort1 context1 prompt1 tag1 driver1 <<< "$LINE1"
IFS='|' read -r model3 provider3 effort3 context3 prompt3 tag3 driver3 <<< "$LINE3"

assert_eq "agent1 model" "claude-opus-4-6" "$model1"
assert_eq "agent1 provider" "anthropic_oauth" "$provider1"
assert_eq "agent1 effort" "high" "$effort1"
assert_eq "agent1 context default" "" "$context1"
assert_eq "agent1 prompt default" "" "$prompt1"
assert_eq "agent1 tag inherits top-level" "top-tag" "$tag1"
assert_eq "agent1 driver inherits top-level" "claude-code" "$driver1"

assert_eq "agent3 model" "openai/gpt-5.4" "$model3"
assert_eq "agent3 provider" "openrouter" "$provider3"
assert_eq "agent3 effort empty" "" "$effort3"
assert_eq "agent3 context" "slim" "$context3"
assert_eq "agent3 prompt" "prompts/review.md" "$prompt3"
assert_eq "agent3 tag override" "review" "$tag3"
assert_eq "agent3 driver explicit" "claude-code" "$driver3"

# ============================================================
echo ""
echo "=== 2. Defaults and legacy-field detection ==="

cat > "$TMPDIR/minimal.json" <<'EOF'
{
  "prompt": "task.md",
  "providers": {
    "anthropic_key": {
      "kind": "anthropic",
      "api_key": "$ANTHROPIC_API_KEY"
    }
  },
  "agents": [
    { "count": 2, "model": "claude-sonnet-4-6", "provider": "anthropic_key" }
  ]
}
EOF

assert_eq "setup default empty" "" "$(parse_setup "$TMPDIR/minimal.json")"
assert_eq "max_idle default" "3" "$(parse_max_idle "$TMPDIR/minimal.json")"
assert_eq "inject_git_rules default" "true" "$(parse_inject_git_rules "$TMPDIR/minimal.json")"
assert_eq "git name default" "swarm-agent" "$(parse_git_name "$TMPDIR/minimal.json")"
assert_eq "git email default" "agent@swarm.local" "$(parse_git_email "$TMPDIR/minimal.json")"
assert_eq "pp model default" "claude-opus-4-6" "$(parse_pp_model "$TMPDIR/minimal.json")"
assert_eq "pp provider default empty" "" "$(parse_pp_provider "$TMPDIR/minimal.json")"

cat > "$TMPDIR/legacy.json" <<'EOF'
{
  "prompt": "task.md",
  "providers": {
    "anthropic_key": {
      "kind": "anthropic",
      "api_key": "$ANTHROPIC_API_KEY"
    }
  },
  "agents": [
    { "count": 1, "model": "claude-opus-4-6", "provider": "anthropic_key", "auth": "oauth" }
  ]
}
EOF

assert_eq "minimal has no legacy auth fields" "false" "$({ has_legacy_auth_fields "$TMPDIR/minimal.json" && echo true; } || echo false)"
assert_eq "legacy auth detected" "true" "$({ has_legacy_auth_fields "$TMPDIR/legacy.json" && echo true; } || echo false)"

# ============================================================
echo ""
echo "=== 3. Checked-in configs are valid v2 examples ==="

for cfg in "$TESTS_DIR"/configs/*.json; do
    name=$(basename "$cfg")
    assert_eq "${name} providers object" "object" "$(jq -r '.providers | type' "$cfg")"
    assert_eq "${name} all agents have provider" "true" \
        "$(jq -r '[.agents[] | has("provider")] | all' "$cfg")"
    assert_eq "${name} no legacy auth fields" "false" \
        "$({ has_legacy_auth_fields "$cfg" && echo true; } || echo false)"

    if jq -e '.post_process' "$cfg" >/dev/null 2>&1; then
        assert_eq "${name} post_process has provider" "true" \
            "$(jq -r '.post_process | has("provider")' "$cfg")"
    fi
done

# ============================================================
echo ""
echo "=== 4. Mixed-provider and kitchen-sink examples ==="

CFG="$TESTS_DIR/configs/mixed-providers.json"
assert_eq "mixed-providers count" "3" "$(parse_num_agents "$CFG")"
assert_eq "mixed-providers provider kinds" "anthropic anthropic-compatible anthropic-compatible" \
    "$(jq -r '[.providers.anthropic_oauth.kind, .providers.openrouter.kind, .providers.minimax.kind] | join(" ")' "$CFG")"
assert_eq "mixed-providers agent providers" "anthropic_oauth openrouter minimax" \
    "$(jq -r '[.agents[].provider] | join(" ")' "$CFG")"

CFG="$TESTS_DIR/configs/kitchen-sink.json"
assert_eq "kitchen-sink count" "6" "$(parse_num_agents "$CFG")"
assert_eq "kitchen-sink top-level driver default" "null" "$(jq -r '.driver // "null"' "$CFG")"
assert_eq "kitchen-sink providers" "4" "$(jq '.providers | length' "$CFG")"
assert_eq "kitchen-sink tag[0]" "deep" "$(jq -r '.agents[0].tag' "$CFG")"
assert_eq "kitchen-sink provider[2]" "anthropic_key" "$(jq -r '.agents[2].provider' "$CFG")"
assert_eq "kitchen-sink provider[4]" "openrouter" "$(jq -r '.agents[4].provider' "$CFG")"
assert_eq "kitchen-sink provider[5]" "minimax" "$(jq -r '.agents[5].provider' "$CFG")"
assert_eq "kitchen-sink pricing model" "0.30" "$(jq -r '.pricing["MiniMax-M2.7"].input' "$CFG")"

# ============================================================
echo ""
echo "=== 5. Codex, OpenCode, Kimi, and Droid examples ==="

CFG="$TESTS_DIR/configs/codex-chatgpt.json"
assert_eq "codex auth-file driver" "codex-cli" "$(jq -r '.driver' "$CFG")"
assert_eq "codex auth-file provider kind" "openai" "$(jq -r '.providers.openai_file.kind' "$CFG")"
assert_eq "codex auth-file path" \~/.codex/auth.json "$(jq -r '.providers.openai_file.auth_file' "$CFG")"
assert_eq "codex auth-file all refs" "openai_file openai_file" "$(jq -r '[.agents[].provider] | join(" ")' "$CFG")"

CFG="$TESTS_DIR/configs/codex-auth-mixed.json"
assert_eq "codex mixed providers" "openai_file openai_key openai_key" "$(jq -r '[.agents[].provider] | join(" ")' "$CFG")"
assert_eq "codex mixed pricing cached" "0.175" "$(jq -r '.pricing["gpt-5.3-codex"].cached' "$CFG")"

CFG="$TESTS_DIR/configs/opencode-only.json"
assert_eq "opencode-only driver" "opencode" "$(jq -r '.driver' "$CFG")"
assert_eq "opencode-only provider kind" "anthropic" "$(jq -r '.providers.anthropic_oauth.kind' "$CFG")"
assert_eq "opencode-only model" "anthropic/claude-sonnet-4-5-20250929" "$(jq -r '.agents[0].model' "$CFG")"

CFG="$TESTS_DIR/configs/kimi-only.json"
assert_eq "kimi-only driver" "kimi-cli" "$(jq -r '.driver' "$CFG")"
assert_eq "kimi-only providers" "kimi kimi" "$(jq -r '[.providers.kimi_default.kind, .providers.kimi_custom.kind] | join(" ")' "$CFG")"
assert_eq "kimi-only custom base_url" "https://api.kimi.com/coding/v1" "$(jq -r '.providers.kimi_custom.base_url' "$CFG")"
assert_eq "kimi-only efforts" "high off" "$(jq -r '[.agents[].effort] | join(" ")' "$CFG")"

CFG="$TESTS_DIR/configs/droid-only.json"
assert_eq "droid-only driver" "droid" "$(jq -r '.driver' "$CFG")"
assert_eq "droid-only provider kind" "factory" "$(jq -r '.providers.factory_key.kind' "$CFG")"
assert_eq "droid-only provider ref" "factory_key" "$(jq -r '.agents[0].provider' "$CFG")"

CFG="$TESTS_DIR/configs/mixed-kimi-claude.json"
assert_eq "mixed-kimi-claude providers" "anthropic_oauth kimi_key" "$(jq -r '[.agents[].provider] | join(" ")' "$CFG")"
assert_eq "mixed-kimi-claude post_process provider" "kimi_key" "$(parse_pp_provider "$CFG")"
assert_eq "mixed-kimi-claude pp driver" "kimi-cli" "$(jq -r '.post_process.driver' "$CFG")"

# ============================================================
echo ""
echo "=== 6. Driver inheritance examples ==="

CFG="$TESTS_DIR/configs/driver-inheritance.json"
assert_eq "driver-inheritance top driver" "gemini-cli" "$(jq -r '.driver' "$CFG")"
assert_eq "driver-inheritance refs" "gemini_key gemini_key" "$(jq -r '[.agents[].provider] | join(" ")' "$CFG")"
assert_eq "driver-inheritance no per-agent driver" "true" "$(jq -r '[.agents[] | has("driver")] | any | not' "$CFG")"

CFG="$TESTS_DIR/configs/driver-post-process.json"
assert_eq "driver-post-process agent driver" "gemini-cli" "$(jq -r '.agents[0].driver' "$CFG")"
assert_eq "driver-post-process pp driver" "gemini-cli" "$(jq -r '.post_process.driver' "$CFG")"
assert_eq "driver-post-process pp provider" "gemini_key" "$(parse_pp_provider "$CFG")"

# ============================================================
echo ""
echo "=== 7. Heterogeneous examples remain expressive ==="

CFG="$TESTS_DIR/configs/heterogeneous-kitchen-sink.json"
assert_eq "hetero count" "7" "$(parse_num_agents "$CFG")"
assert_eq "hetero pp provider" "anthropic_oauth" "$(parse_pp_provider "$CFG")"
assert_eq "hetero gemini refs" "5" "$(jq '[.agents[] | select(.provider == "gemini_key")] | length' "$CFG")"
assert_eq "hetero claude refs" "2" "$(jq '[.agents[] | select(.driver == "claude-code")] | length' "$CFG")"
assert_contains "hetero gemini preview present" "gemini-3.1-pro-preview-customtools" "$(jq -r '[.agents[].model] | join(" ")' "$CFG")"

echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
