#!/bin/bash
set -euo pipefail

# shellcheck source=_test_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_test_env.sh"

# Unit tests for lib/coverage.sh and coverage.sh --logs.
# No Docker or API key required.  Log fixtures follow the Claude
# Code stream-json shape: tool_use in assistant messages, and
# tool_result plus top-level tool_use_result in user messages.

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SWARM_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=../lib/coverage.sh
source "$SWARM_DIR/lib/coverage.sh"

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

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

# Emit an assistant tool_use line.
# Args: <id> <name> <input_json>
tool_use() {
    jq -cn --arg id "$1" --arg name "$2" --argjson input "$3" \
        '{type: "assistant", message: {content: [
            {type: "tool_use", id: $id, name: $name, input: $input}]}}'
}

# Emit a user tool_result line.
# Args: <id> <tool_use_result_json> [is_error]
tool_result() {
    jq -cn --arg id "$1" --argjson tur "$2" \
        --argjson err "${3:-false}" \
        '{type: "user", message: {content: [
            {type: "tool_result", tool_use_id: $id, content: "x",
             is_error: $err}]}, tool_use_result: $tur}'
}

ROOT="$TMPDIR/src"
mkdir -p "$ROOT/lib" "$TMPDIR/logs"
seq 1 100 | sed 's/^/line /' > "$ROOT/lib/a.go"
seq 1 10 | sed 's/^/line /' > "$ROOT/lib/b.go"
seq 1 5 | sed 's/^/line /' > "$ROOT/lib/never.go"

# ============================================================
echo "=== 1. Read tool: metadata preferred over input ==="

LOG1="$TMPDIR/logs/agent_1_abc123_1700000000.log"
{
    tool_use r1 Read '{"file_path":"/workspace/lib/a.go","offset":10,
        "limit":5}'
    tool_result r1 '{"type":"text","file":{"filePath":
        "/workspace/lib/a.go","startLine":10,"numLines":11,
        "totalLines":100}}'
    tool_use r2 Read '{"file_path":"/workspace/lib/b.go"}'
    tool_result r2 '{"type":"text"}'
    tool_use r3 Read '{"file_path":"/workspace/lib/a.go","offset":90,
        "limit":5}'
    tool_result r3 '{}' true
} > "$LOG1"

rows=$(coverage_extract_ranges "$LOG1" 1 /workspace/)
assert_eq "metadata range wins" \
    "1	lib/a.go	10	20	read" "$(sed -n 1p <<< "$rows")"
assert_eq "no metadata or limit reads to EOF" \
    "1	lib/b.go	1	EOF	read" "$(sed -n 2p <<< "$rows")"
assert_eq "errored Read is ignored" "2" "$(wc -l <<< "$rows" | tr -d ' ')"

# ============================================================
echo "=== 2. Shell reads: deterministic subset ==="

LOG2="$TMPDIR/logs/agent_2_def456_1700000001.log"
{
    tool_use b1 Bash \
        '{"command":"sed -n '"'"'30,40p'"'"' /workspace/lib/a.go"}'
    tool_result b1 '{"stdout":"x"}'
    tool_use b2 Bash '{"command":"nl -ba lib/a.go | sed -n '"'"'45,50p'"'"'"}'
    tool_result b2 '{"stdout":"x"}'
    tool_use b3 Bash '{"command":"head -n 3 lib/b.go && tail -n 2 lib/b.go"}'
    tool_result b3 '{"stdout":"x"}'
    tool_use b4 Bash '{"command":"cat lib/b.go; grep -n foo lib/a.go"}'
    tool_result b4 '{"stdout":"x"}'
    tool_use b5 Bash '{"command":"make test"}'
    tool_result b5 '{"stdout":"x"}'
} > "$LOG2"

rows=$(coverage_extract_ranges "$LOG2" 2 /workspace/)
assert_eq "sed -n range with prefix strip" \
    "2	lib/a.go	30	40	sed" "$(sed -n 1p <<< "$rows")"
assert_eq "nl -ba | sed -n range" \
    "2	lib/a.go	45	50	nl" "$(sed -n 2p <<< "$rows")"
assert_eq "head -n in first segment" \
    "2	lib/b.go	1	3	head" "$(sed -n 3p <<< "$rows")"
assert_eq "tail -n in second segment" \
    "2	lib/b.go	-2	EOF	tail" "$(sed -n 4p <<< "$rows")"
assert_eq "cat whole file" \
    "2	lib/b.go	1	EOF	cat" "$(sed -n 5p <<< "$rows")"
assert_eq "grep counted as unresolved" \
    "2	-	0	0	unresolved" "$(sed -n 6p <<< "$rows")"
assert_eq "non-read command ignored" "6" \
    "$(wc -l <<< "$rows" | tr -d ' ')"

# ============================================================
echo "=== 3. Resolve and merge ==="

merged=$( { coverage_extract_ranges "$LOG1" 1 /workspace/
            coverage_extract_ranges "$LOG2" 2 /workspace/; } \
    | coverage_resolve_ranges "$ROOT" | coverage_merge)
assert_eq "a.go merged ranges and agents" \
    "lib/a.go	28	100	28.0	1,2	10-20,30-40,45-50" \
    "$(grep '^lib/a.go' <<< "$merged")"
assert_eq "b.go fully covered by two agents" \
    "lib/b.go	10	10	100.0	1,2	1-10" \
    "$(grep '^lib/b.go' <<< "$merged")"

# ============================================================
echo "=== 4. Gaps ==="

assert_eq "gaps inside and after ranges" "1-9,21-29,41-44,51-100" \
    "$(coverage_gaps "10-20,30-40,45-50" 100)"
assert_eq "no gaps when fully covered" "" "$(coverage_gaps "1-10" 10)"
assert_eq "adjacent ranges leave no gap" "" \
    "$(coverage_gaps "1-4,5-10" 10)"

# ============================================================
echo "=== 5. CLI with --logs, --targets, --json, --prompt-out ==="

printf 'lib/*.go\n# comment\n' > "$TMPDIR/targets.txt"
json=$("$SWARM_DIR/coverage.sh" --logs "$TMPDIR/logs" --root "$ROOT" \
    --targets "$TMPDIR/targets.txt" --json \
    --prompt-out "$TMPDIR/followup.md")
assert_eq "json log count" "2" "$(jq '.logs' <<< "$json")"
assert_eq "json unresolved count" "1" "$(jq '.unresolved' <<< "$json")"
assert_eq "json never-read target" '["1-5"]' \
    "$(jq -c '.targets[] | select(.path == "lib/never.go") | .unread' \
        <<< "$json")"
assert_eq "json partial target gaps" '["1-9","21-29","41-44","51-100"]' \
    "$(jq -c '.targets[] | select(.path == "lib/a.go") | .unread' \
        <<< "$json")"
assert_eq "prompt lists never-read file" "- \`lib/never.go\`" \
    "$(grep 'never.go' "$TMPDIR/followup.md")"
assert_eq "prompt lists partial gaps" \
    "- \`lib/a.go\`: 1-9, 21-29, 41-44, 51-100" \
    "$(grep 'a.go' "$TMPDIR/followup.md")"

rc=0
"$SWARM_DIR/coverage.sh" --logs "$TMPDIR/logs" --root "$ROOT" \
    --targets "$TMPDIR/targets.txt" --fail-under 50 >/dev/null || rc=$?
assert_eq "--fail-under exits 2 below threshold" "2" "$rc"

rc=0
"$SWARM_DIR/coverage.sh" --logs "$TMPDIR/logs" --root "$ROOT" \
    --prompt-out "$TMPDIR/x.md" >/dev/null 2>&1 || rc=$?
assert_eq "--prompt-out without --targets is rejected" "1" "$rc"

table=$("$SWARM_DIR/coverage.sh" --logs "$TMPDIR/logs" --root "$ROOT" \
    --targets "$TMPDIR/targets.txt")
assert_eq "table target summary" \
    "Targets: 3 file(s), 1 fully read, 1 partial, 1 never read" \
    "$(grep '^Targets:' <<< "$table")"

# ============================================================
echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
