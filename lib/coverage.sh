#!/bin/bash

# Post-hoc read coverage for swarm sessions.
#
# Parses agent JSONL session logs (Claude Code `stream-json`),
# extracts the file line ranges each agent actually read, and
# merges them into per-file coverage.  Sourced by coverage.sh and
# by tests/test_coverage.sh; no Docker access here.
#
# Range sources:
# - `Read` tool calls.  The tool result metadata
#   (`tool_use_result.file.startLine/numLines`) is preferred; the
#   call's `offset`/`limit` input is the fallback.
# - `Bash` commands in a deterministic subset:
#   `sed -n 'A,Bp' F`, `nl -ba F | sed -n 'A,Bp'`, `cat [-n] F`,
#   `head -n N F`, `head -N F`, `tail -n N F`.  Segments joined by
#   `&&` or `;` are parsed independently.  Other read-like commands
#   are counted as unresolved and never guessed.
#
# Range rows are TSV: agent, path, start, end, source.  `end` is
# `EOF` for whole-file reads; `start` is `-N` for `tail -n N`.

# Emit range rows for one log file.
# Args: <logfile> <agent_id> <strip_prefix>
coverage_extract_ranges() {
    local logfile="$1" agent="$2" strip="${3:-}"
    local q="[\"']?" f="(?<p>\\S+)"
    local re_nl="^nl -ba ${f}\\s*\\|\\s*sed -n ${q}(?<a>[0-9]+),"
    re_nl+="(?<b>[0-9]+)p${q}\$"
    local re_sed="^sed -n ${q}(?<a>[0-9]+),(?<b>[0-9]+)p${q} ${f}\$"
    local re_cat="^cat( -n)? ${f}\$"
    local re_head="^head -(n ?)?(?<n>[0-9]+) ${f}\$"
    local re_tail="^tail -n ?(?<n>[0-9]+) ${f}\$"
    local re_any="^(cat|sed|head|tail|nl|less|more|awk|grep|rg|bat)\\b"
    jq -r -s --arg agent "$agent" --arg strip "$strip" \
        --arg re_nl "$re_nl" --arg re_sed "$re_sed" \
        --arg re_cat "$re_cat" --arg re_head "$re_head" \
        --arg re_tail "$re_tail" --arg re_any "$re_any" '
      def strip_p:
        if ($strip != "" and startswith($strip))
        then .[($strip | length):] else . end;
      def unq: gsub("^[\"\u0027]|[\"\u0027]$"; "");
      def m($re): [capture($re)] | .[0];
      def seg_ranges:
        gsub("^\\s+|\\s+$"; "") as $s
        | if ($s | m($re_nl)) then ($s | m($re_nl))
               | [(.p | unq), .a, .b, "nl"]
          elif ($s | m($re_sed)) then ($s | m($re_sed))
               | [(.p | unq), .a, .b, "sed"]
          elif ($s | m($re_cat)) then ($s | m($re_cat))
               | [(.p | unq), "1", "EOF", "cat"]
          elif ($s | m($re_head)) then ($s | m($re_head))
               | [(.p | unq), "1", .n, "head"]
          elif ($s | m($re_tail)) then ($s | m($re_tail))
               | [(.p | unq), ("-" + .n), "EOF", "tail"]
          elif ($s | test($re_any)) then ["-", "0", "0", "unresolved"]
          else empty end;
      (map(select(.type == "user")
           | . as $u
           | (.message.content // [])[]?
           | select(type == "object" and .type == "tool_result")
           | {key: .tool_use_id,
              value: {meta: ($u.tool_use_result // {}),
                      err: (.is_error // false)}})
       | from_entries) as $res
      | .[]
      | select(.type == "assistant")
      | (.message.content // [])[]?
      | select(type == "object" and .type == "tool_use")
      | . as $t
      | ($res[$t.id] // {meta: {}, err: false}) as $r
      | if $t.name == "Read" and ($r.err | not) then
          (($r.meta | objects | .file) // {}) as $f
          | ($f.filePath // $t.input.file_path) as $p
          | select($p != null)
          | ($f.startLine // $t.input.offset // 1) as $s
          | (if ($f.numLines // 0) > 0 then $s + $f.numLines - 1
             elif ($t.input.limit // 0) > 0
             then $s + $t.input.limit - 1
             else "EOF" end) as $e
          | [$agent, ($p | strip_p), ($s | tostring), ($e | tostring),
             "read"]
        elif $t.name == "Bash" and ($r.err | not) then
          ($t.input.command // "")
          | [splits("&&|;|\n")]
          | .[]
          | seg_ranges
          | [$agent, (.[0] | if . == "-" then . else strip_p end),
             .[1], .[2], .[3]]
        else empty end
      | @tsv
    ' "$logfile"
}

# Print the line count of <root>/<path>, or "?" when unreadable.
# Args: <root> <path>
coverage_file_lines() {
    local root="$1" path="$2" full
    case "$path" in
        /*) full="$path" ;;
        *) full="${root%/}/$path" ;;
    esac
    if [ -f "$full" ] && [ -r "$full" ]; then
        awk 'END { print NR }' "$full"
    else
        echo "?"
    fi
}

# Resolve EOF/tail rows against file sizes and drop unresolved rows.
# Reads range rows on stdin; writes rows with numeric start/end.
# Args: <root>
coverage_resolve_ranges() {
    local root="$1" agent path start end src total i n
    # Parallel indexed arrays, not `declare -A`: /bin/bash on macOS
    # is 3.2, which has no associative arrays.
    local -a size_paths=() size_totals=()
    while IFS=$'\t' read -r agent path start end src; do
        if [ "$src" = "unresolved" ] || [ "$path" = "-" ]; then
            continue
        fi
        total=""
        n=${#size_paths[@]}
        for (( i = 0; i < n; i++ )); do
            if [ "${size_paths[i]}" = "$path" ]; then
                total="${size_totals[i]}"
                break
            fi
        done
        if [ -z "$total" ]; then
            total="$(coverage_file_lines "$root" "$path")"
            size_paths[n]="$path"
            size_totals[n]="$total"
        fi
        if [ "$end" = "EOF" ]; then
            if [ "$total" = "?" ]; then
                continue
            fi
            end="$total"
        fi
        if [ "${start:0:1}" = "-" ]; then
            start=$(( total - ${start:1} + 1 ))
            if [ "$start" -lt 1 ]; then
                start=1
            fi
        fi
        if [ "$total" != "?" ] && [ "$end" -gt "$total" ]; then
            end="$total"
        fi
        if [ "$end" -lt "$start" ]; then
            continue
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$agent" "$path" "$start" "$end" "$src" "$total"
    done
}

# Merge resolved rows into per-file coverage.
# Output TSV: path, covered, total, percent, agents, ranges.
# `ranges` is a comma-separated list of merged A-B intervals.
coverage_merge() {
    sort -t$'\t' -k2,2 -k3,3n | awk -F'\t' '
      function flush(   pct) {
        if (cur == "") { return }
        if (s != "") { covered += e - s + 1; add_range(s, e) }
        pct = (tot == "?" || tot == 0) ? "?" \
              : sprintf("%.1f", 100 * covered / tot)
        printf "%s\t%d\t%s\t%s\t%s\t%s\n", \
            cur, covered, tot, pct, agents, ranges
      }
      function add_range(a, b) {
        ranges = ranges (ranges == "" ? "" : ",") a "-" b
      }
      {
        if ($2 != cur) {
          flush()
          cur = $2; tot = $6; covered = 0; s = ""; e = ""
          agents = ""; ranges = ""; delete seen
        }
        if (!($1 in seen)) {
          seen[$1] = 1
          agents = agents (agents == "" ? "" : ",") $1
        }
        if (s == "") { s = $3; e = $4 }
        else if ($3 <= e + 1) { if ($4 > e) { e = $4 } }
        else { covered += e - s + 1; add_range(s, e); s = $3; e = $4 }
      }
      END { flush() }
    ' | while IFS=$'\t' read -r path cov tot pct ags ranges; do
        ags="$(printf '%s\n' "${ags//,/$'\n'}" | sort -V | paste -sd, -)"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$path" "$cov" "$tot" "$pct" "$ags" "$ranges"
    done
}

# Expand target pathspecs (one per line, `#` comments allowed) into
# tracked files under <root>.  Non-git roots fall back to shell globs.
# Args: <root> <targets_file>
coverage_expand_targets() {
    local root="${1%/}" targets="$2" line f is_git=false
    if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
        is_git=true
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | sed 's/[[:space:]]*$//')"
        if [ -z "$line" ]; then
            continue
        fi
        if $is_git; then
            git -C "$root" ls-files -- "$line"
            continue
        fi
        for f in "$root"/$line; do
            if [ -f "$f" ]; then
                printf '%s\n' "${f#"$root"/}"
            fi
        done
    done < "$targets" | sort -u
}

# Complement of merged ranges within [1, total]: "A-B,C-D" or "".
# Args: <ranges> <total>
coverage_gaps() {
    local ranges="$1" total="$2"
    awk -v r="$ranges" -v t="$total" 'BEGIN {
        n = split(r, parts, ","); next_line = 1; out = ""
        for (i = 1; i <= n; i++) {
            if (parts[i] == "") { continue }
            split(parts[i], ab, "-")
            if (ab[1] > next_line) {
                out = out (out == "" ? "" : ",") next_line "-" (ab[1] - 1)
            }
            if (ab[2] + 1 > next_line) { next_line = ab[2] + 1 }
        }
        if (t != "?" && next_line <= t) {
            out = out (out == "" ? "" : ",") next_line "-" t
        }
        print out
    }'
}
