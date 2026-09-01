#!/bin/bash
set -euo pipefail

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CLONE_HELPER="$TESTS_DIR/../lib/upstream-clone.sh"
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

# shellcheck disable=SC1090
source "$CLONE_HELPER"

INFO_LOG="$TMPDIR/info.log"
ERROR_LOG="$TMPDIR/error.log"

test_log() {
    printf '%s\n' "$*" >> "$INFO_LOG"
}

test_log_err() {
    printf '%s\n' "$*" >> "$ERROR_LOG"
}

echo "=== 1. Entrypoints use the shared transport clone ==="

assert_eq "helper uses --no-local" "1" \
    "$(grep -cF 'git clone -q --no-local' "$CLONE_HELPER")"
assert_eq "harness sources clone helper" "1" \
    "$(grep -cF 'source /upstream-clone.sh' \
        "$TESTS_DIR/../lib/harness.sh")"
assert_eq "interactive sources clone helper" "1" \
    "$(grep -cF 'source /upstream-clone.sh' \
        "$TESTS_DIR/../lib/interactive.sh")"
assert_eq "Dockerfile installs clone helper" "1" \
    "$(grep -cF \
        'COPY --chmod=644 lib/upstream-clone.sh /upstream-clone.sh' \
        "$TESTS_DIR/../Dockerfile")"

echo ""
echo "=== 2. Transient failures retry and then succeed ==="

SOURCE_WORK="$TMPDIR/source-work"
SOURCE_BARE="$TMPDIR/source.git"
DESTINATION="$TMPDIR/destination"
FAKE_BIN="$TMPDIR/bin"
GIT_COUNT="$TMPDIR/git-count"
GIT_ARGS="$TMPDIR/git-args"
SLEEP_ARGS="$TMPDIR/sleep-args"
REAL_GIT=$(command -v git)

mkdir -p "$SOURCE_WORK" "$FAKE_BIN"
git init -q "$SOURCE_WORK"
git -C "$SOURCE_WORK" config user.name test
git -C "$SOURCE_WORK" config user.email test@example.com
git -C "$SOURCE_WORK" config commit.gpgsign false
printf 'bootstrap clone fixture\n' > "$SOURCE_WORK/fixture.txt"
git -C "$SOURCE_WORK" add fixture.txt
git -C "$SOURCE_WORK" commit -q -m "Seed fixture"
git clone -q --bare "$SOURCE_WORK" "$SOURCE_BARE"

cat > "$FAKE_BIN/git" <<'EOF'
#!/bin/bash
count=0
if [ -f "$GIT_COUNT" ]; then
    count=$(cat "$GIT_COUNT")
fi
count=$((count + 1))
printf '%s\n' "$count" > "$GIT_COUNT"
printf '%s\n' "$*" >> "$GIT_ARGS"
if [ "$count" -le "$GIT_FAILURES" ]; then
    echo "fatal: simulated transient Permission denied" >&2
    exit 128
fi
exec "$REAL_GIT" "$@"
EOF
chmod +x "$FAKE_BIN/git"

cat > "$FAKE_BIN/sleep" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" >> "$SLEEP_ARGS"
EOF
chmod +x "$FAKE_BIN/sleep"

export GIT_COUNT GIT_ARGS SLEEP_ARGS REAL_GIT
export GIT_FAILURES=2

PATH="$FAKE_BIN:$PATH" \
    swarm_clone_upstream \
        "$SOURCE_BARE" "$DESTINATION" test_log test_log_err

assert_eq "clone succeeds on third attempt" "3" \
    "$(cat "$GIT_COUNT")"
assert_eq "every attempt disables local copying" "3" \
    "$(grep -cF 'clone -q --no-local' "$GIT_ARGS")"
assert_eq "backoff sleeps for one and two seconds" $'1\n2' \
    "$(cat "$SLEEP_ARGS")"
assert_eq "cloned repository has expected HEAD" \
    "$(git -C "$SOURCE_BARE" rev-parse HEAD)" \
    "$(git -C "$DESTINATION" rev-parse HEAD)"
assert_eq "two retry errors are logged" "2" \
    "$(grep -cF 'retrying in' "$ERROR_LOG")"

echo ""
echo "=== 3. Persistent failures stop after five attempts ==="

rm -rf "$DESTINATION"
: > "$GIT_COUNT"
: > "$GIT_ARGS"
: > "$SLEEP_ARGS"
: > "$ERROR_LOG"
export GIT_FAILURES=99

clone_rc=0
PATH="$FAKE_BIN:$PATH" \
    swarm_clone_upstream \
        "$SOURCE_BARE" "$DESTINATION" test_log test_log_err \
    || clone_rc=$?

assert_eq "persistent failure returns non-zero" "1" "$clone_rc"
assert_eq "persistent failure attempts five clones" "5" \
    "$(cat "$GIT_COUNT")"
assert_eq "bounded backoff totals four sleeps" $'1\n2\n4\n8' \
    "$(cat "$SLEEP_ARGS")"
assert_eq "terminal failure is logged once" "1" \
    "$(grep -cF 'upstream clone failed after 5 attempts' \
        "$ERROR_LOG")"

echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
