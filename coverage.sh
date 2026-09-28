#!/bin/bash
set -euo pipefail

# Post-hoc read coverage: which files and lines did agents read?
# Usage: ./coverage.sh [OPTIONS]

SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    cat <<HELP
Usage: $0 [OPTIONS]

Report which files and line ranges swarm agents actually read, by
parsing their session logs (Read tool calls and simple shell reads).

Options:
  --logs DIR         Read agent_*.log files from DIR instead of the
                     swarm containers.  Repeatable.
  --root DIR         Source tree for line counts and targets
                     (default: repository root).
  --strip PREFIX     Path prefix to remove from logged paths
                     (default: /workspace/).
  --targets FILE     Git pathspecs (one per line) that should have
                     been read.  Enables the gap report.
  --prompt-out FILE  Write a follow-up prompt listing unread target
                     code (requires --targets).
  --fail-under PCT   Exit 2 if any target is below PCT percent read
                     (requires --targets).
  --json             Output JSON instead of a table.
  -h, --help         Show this help message.

Without --logs, logs are copied from swarm containers (numbered
agents and post-process) via docker cp, like costs.sh.
HELP
}

LOG_DIRS=()
ROOT=""
STRIP="/workspace/"
TARGETS=""
PROMPT_OUT=""
FAIL_UNDER=""
JSON_MODE=false

while [ $# -gt 0 ]; do
    case "$1" in
        --logs) LOG_DIRS+=("$2"); shift 2 ;;
        --root) ROOT="$2"; shift 2 ;;
        --strip) STRIP="$2"; shift 2 ;;
        --targets) TARGETS="$2"; shift 2 ;;
        --prompt-out) PROMPT_OUT="$2"; shift 2 ;;
        --fail-under) FAIL_UNDER="$2"; shift 2 ;;
        --json) JSON_MODE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

source "$SWARM_DIR/lib/check-deps.sh"
check_deps git jq awk
# shellcheck source=lib/coverage.sh
source "$SWARM_DIR/lib/coverage.sh"

if { [ -n "$PROMPT_OUT" ] || [ -n "$FAIL_UNDER" ]; } \
        && [ -z "$TARGETS" ]; then
    echo "ERROR: --prompt-out and --fail-under need --targets." >&2
    exit 1
fi
if [ -n "$TARGETS" ] && [ ! -f "$TARGETS" ]; then
    echo "ERROR: targets file not found: $TARGETS" >&2
    exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ -z "$ROOT" ]; then
    ROOT="$REPO_ROOT"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Collect logs from containers when no --logs directory is given.
if [ ${#LOG_DIRS[@]} -eq 0 ]; then
    check_deps docker
    # shellcheck source=lib/project.sh
    source "$SWARM_DIR/lib/project.sh"
    PROJECT="$(swarm_project_id "$(basename "$REPO_ROOT")")"
    containers=$(docker ps -a --filter "name=${PROJECT}-agent-" \
        --format '{{.Names}}' 2>/dev/null | sort -V || true)
    if [ -z "$containers" ]; then
        echo "No swarm containers found." >&2
        exit 1
    fi
    for cname in $containers; do
        mkdir -p "$WORK/logs/$cname"
        docker cp "${cname}:/workspace/agent_logs/." \
            "$WORK/logs/$cname/" >/dev/null 2>&1 || true
    done
    LOG_DIRS=("$WORK/logs")
fi

log_count=0
: > "$WORK/rows.tsv"
for dir in "${LOG_DIRS[@]}"; do
    while IFS= read -r log; do
        base="$(basename "$log")"
        agent="${base#agent_}"
        agent="${agent%%_*}"
        coverage_extract_ranges "$log" "$agent" "$STRIP" \
            >> "$WORK/rows.tsv" || true
        log_count=$((log_count + 1))
    done < <(find "$dir" -type f -name 'agent_*.log' | sort)
done

unresolved=$(awk -F'\t' '$5 == "unresolved"' "$WORK/rows.tsv" \
    | wc -l | tr -d ' ')
reads=$(awk -F'\t' '$5 != "unresolved"' "$WORK/rows.tsv" \
    | wc -l | tr -d ' ')
agents=$(awk -F'\t' '{ print $1 }' "$WORK/rows.tsv" | sort -u \
    | paste -sd, -)

coverage_resolve_ranges "$ROOT" < "$WORK/rows.tsv" \
    | coverage_merge > "$WORK/files.tsv"

# Target gap analysis.
: > "$WORK/targets.tsv"
if [ -n "$TARGETS" ]; then
    while IFS= read -r t; do
        row=$(awk -F'\t' -v p="$t" '$1 == p' "$WORK/files.tsv")
        total=$(coverage_file_lines "$ROOT" "$t")
        if [ -z "$row" ]; then
            printf '%s\t0\t%s\t0.0\t\t\t1-%s\n' "$t" "$total" "$total" \
                >> "$WORK/targets.tsv"
        else
            ranges=$(printf '%s' "$row" | cut -f6)
            gaps=$(coverage_gaps "$ranges" "$total")
            printf '%s\t%s\n' "$row" "$gaps" >> "$WORK/targets.tsv"
        fi
    done < <(coverage_expand_targets "$ROOT" "$TARGETS")
fi

n_targets=$(wc -l < "$WORK/targets.tsv" | tr -d ' ')
n_full=$(awk -F'\t' '$7 == ""' "$WORK/targets.tsv" \
    | wc -l | tr -d ' ')
n_unread=$(awk -F'\t' '$2 == 0' "$WORK/targets.tsv" \
    | wc -l | tr -d ' ')
n_partial=$((n_targets - n_full - n_unread))

if $JSON_MODE; then
    jq -n \
        --argjson logs "$log_count" \
        --argjson reads "$reads" \
        --argjson unresolved "$unresolved" \
        --arg agents "$agents" \
        --rawfile files "$WORK/files.tsv" \
        --rawfile targets "$WORK/targets.tsv" \
        --argjson has_targets "$([ -n "$TARGETS" ] && echo true \
            || echo false)" '
      def rows($s): $s | split("\n") | map(select(. != "")
        | split("\t"));
      def num: if . == "?" then null else tonumber end;
      def list: if . == "" then [] else split(",") end;
      {
        logs: $logs, reads: $reads, unresolved: $unresolved,
        agents: ($agents | list),
        files: [rows($files)[] | {
          path: .[0], covered: (.[1] | tonumber), total: (.[2] | num),
          percent: (.[3] | num), agents: (.[4] | list),
          ranges: (.[5] | list)}]
      }
      + (if $has_targets then {targets: [rows($targets)[] | {
          path: .[0], covered: (.[1] | tonumber), total: (.[2] | num),
          percent: (.[3] | num), agents: (.[4] | list),
          unread: (.[6] | list)}]} else {} end)'
else
    printf 'Coverage: %s log(s), %s read(s), %s unresolved shell' \
        "$log_count" "$reads" "$unresolved"
    printf ' read(s), agents: %s\n\n' "${agents:-none}"
    printf '%-50s %13s %7s  %s\n' "File" "Lines" "%" "Agents"
    printf '%s\n' "$(printf '%.0s-' $(seq 1 79))"
    while IFS=$'\t' read -r path cov tot pct ags _ranges; do
        printf '%-50s %13s %7s  %s\n' "$path" "${cov}/${tot}" \
            "$pct" "$ags"
    done < "$WORK/files.tsv"
    if [ -n "$TARGETS" ]; then
        printf '\nTargets: %s file(s), %s fully read, %s partial,' \
            "$n_targets" "$n_full" "$n_partial"
        printf ' %s never read\n' "$n_unread"
        if [ "$n_unread" -gt 0 ]; then
            echo "Never read:"
            awk -F'\t' '$2 == 0 { print "  " $1 }' "$WORK/targets.tsv"
        fi
    fi
fi

if [ -n "$PROMPT_OUT" ]; then
    {
        echo "# Coverage follow-up"
        echo
        echo "A previous swarm run did not read the target code below."
        echo "Continue the same task, starting with files never read,"
        echo "then the unread line ranges of partially read files."
        echo
        if [ "$n_unread" -gt 0 ]; then
            echo "## Never read"
            echo
            awk -F'\t' '$2 == 0 { print "- `" $1 "`" }' \
                "$WORK/targets.tsv"
            echo
        fi
        if [ "$n_partial" -gt 0 ]; then
            echo "## Partially read (unread lines)"
            echo
            awk -F'\t' '$2 > 0 && $7 != "" {
                gsub(",", ", ", $7); print "- `" $1 "`: " $7 }' \
                "$WORK/targets.tsv"
            echo
        fi
    } > "$PROMPT_OUT"
fi

if [ -n "$FAIL_UNDER" ]; then
    below=$(awk -F'\t' -v f="$FAIL_UNDER" \
        '$4 == "?" || $4 + 0 < f + 0' "$WORK/targets.tsv" \
        | wc -l | tr -d ' ')
    if [ "$below" -gt 0 ]; then
        exit 2
    fi
fi
