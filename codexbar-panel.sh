#!/usr/bin/env bash
# codexbar-panel - render AI coding-assistant usage limits as fixed-width rows.
#
# Designed as the backing command for a desktop panel widget (originally the
# KDE Plasma "Command Output" plasmoid, com.github.zren.commandoutput), but it
# is a plain script and prints to stdout, so anything that can run a command
# and show its output will work.
#
#   codexbar-panel            one row per rate window, for the panel
#   codexbar-panel --details  multi-line per-provider detail, for a tooltip
#   codexbar-panel --popup    the same detail in a kdialog textbox
#
# Panel output packs two windows per line: full provider name, compact window
# label, five-cell percent-left meter, exact headroom, and compact reset time.
#
#   Codex W    ███░░ 56% 3d21h    Claude 5h  ████░ 70% 3h51m
#   Grok M     ████░ 75% 29d      Claude W   █████ 96% 2d1h
#
# See README.md for requirements and for the Plasma widget settings.

set -euo pipefail

# "<codexbar provider slug>:<panel label>:<detail label>", in display order.
# The panel label is kept short because it repeats once per rate window; the
# detail view has room for the full name.
PROVIDERS=("codex:Codex:Codex" "claude:Claude:Claude Code" "grok:Grok:Grok")

# Column at which the values start inside one cell. Shared by the jq padding
# and the shell fallbacks so the two cannot drift apart.
PAD_WIDTH="${CODEXBAR_PANEL_PAD_WIDTH:-11}"

# Display width for the left cell in a packed panel row. The right cell starts
# after this width plus the separator, so differing percentages and reset
# strings cannot push the second column sideways.
CELL_WIDTH="${CODEXBAR_PANEL_CELL_WIDTH:-27}"

# Panel widgets typically refresh on a timer that only restarts once this
# process exits, so an unbounded fetch would freeze the widget rather than
# just skip a cycle. Every codexbar call is bounded by this.
FETCH_TIMEOUT="${CODEXBAR_PANEL_TIMEOUT:-45}"

# Detail text cache used by --popup. Panel refreshes update it after fetching;
# clicks read it immediately and only fetch when the cache has not been seeded.
CACHE_FILE="${CODEXBAR_PANEL_CACHE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/codexbar-panel/details.txt}"

# Shared jq definitions, used by both the panel rows and the detail view.
#
# Reset times are always derived from `resetsAt`. The providers' own
# `resetDescription` is unreliable: Claude returns it with the spaces stripped,
# e.g. "Resets5:30pm(Europe/Sofia)".
#
# This is a quoted heredoc, so nothing here is expanded by the shell and
# apostrophes are safe. Call sites concatenate "$JQ_DEFS" with a short
# single-quoted expression; keep that expression free of apostrophes.
JQ_DEFS="$(
    cat <<'JQ'
def secsUntil($iso):
  if $iso == null then null
  else ($iso | fromdateiso8601? // null) as $t
    | if $t == null then null else (($t - now) | floor) end
  end;

# Compact "3d 21h" / "4h 28m" / "12m" form. Components are floored so the
# remaining time is never overstated.
def resetShort($iso):
  secsUntil($iso) as $s
  | if $s == null then "?"
    elif $s <= 0 then "0m"
    else ($s / 86400 | floor) as $d
      | (($s - $d * 86400) / 3600 | floor) as $h
      | (($s - $d * 86400 - $h * 3600) / 60 | floor) as $m
      | if $d > 0 then "\($d)d \($h)h"
        elif $h > 0 then "\($h)h \($m)m"
        else "\($m)m"
        end
    end;

def resetLong($iso):
  ($iso | fromdateiso8601? // null) as $t
  | if $t == null then "reset unknown"
    else "resets in \(resetShort($iso)) (\($t | strflocaltime("%b %-d, %H:%M")))"
    end;

# The provider's main rate windows.
def lanes:
  [ (.usage.primary?), (.usage.secondary?), (.usage.tertiary?) ]
  | map(select(type == "object" and .usedPercent != null));

# Provider-specific extra windows (e.g. Codex Spark). Detail view only, so the
# panel row count stays predictable.
def extraLanes:
  [ (.usage.extraRateWindows? // [])[]
    | select((.window? // null) != null)
    | .window + { title: (.title // .id) } ];

# The window closest to exhaustion: the limit that will bind first.
def bindingLane:
  lanes | sort_by(.usedPercent) | last;

# Floored so headroom is never overstated, and clamped in case a provider ever
# reports a percentage outside 0-100.
def percentLeft:
  ((100 - .usedPercent) | floor)
  | if . < 0 then 0 elif . > 100 then 100 else . end;

# Compact window name for the "<provider> <window>" row prefix.
def laneShort:
  if (.windowMinutes // 0) == 300 then "5h"
  elif (.windowMinutes // 0) == 10080 then "W"
  elif ((.windowMinutes // 0) >= 40000 and (.windowMinutes // 0) <= 45000) then "M"
  elif (.windowMinutes // null) != null then "\(.windowMinutes)m"
  else "--"
  end;

# Right-pads to a fixed column so the values line up. Needs a monospace font
# in the widget. In jq, string * 0 yields null rather than the empty string,
# but null is the identity for + on strings, so clamping at 0 is safe.
def padTo($n):
  . + (" " * ([$n - length, 0] | max));

# Five-cell headroom meter. Rounded to the nearest 20% so the widget stays
# narrow while still showing rough battery-style capacity.
def glyphBar:
  percentLeft as $p
  | ([ (($p / 20 + 0.5) | floor), 5 ] | min) as $filled
  | ("█" * $filled) + ("░" * (5 - $filled));

# Panel reset text has no prose or spaces. Long monthly windows keep days only
# so the Grok row stays narrow, while shorter windows keep the useful hour/minute.
def resetPanel($iso):
  secsUntil($iso) as $s
  | if $s == null then "reset unknown"
    elif $s <= 0 then "0m"
    else ($s / 86400 | floor) as $d
      | (($s - $d * 86400) / 3600 | floor) as $h
      | (($s - $d * 86400 - $h * 3600) / 60 | floor) as $m
      | if $d >= 7 then "\($d)d"
        elif $d > 0 then "\($d)d\($h)h"
        elif $h > 0 then "\($h)h\($m)m"
        else "\($m)m"
        end
    end;

# One row per main rate window, shortest window first. A provider with no
# usable window still yields exactly one row, so a panel widget never renders
# blank.
def panelRows($label; $pad):
  (lanes | sort_by(.windowMinutes // 0)) as $ls
  | if ($ls | length) == 0
    then [ ($label | padTo($pad)) + "usage unavailable" ]
    else $ls
      | map(
          ("\($label) \(laneShort)" | padTo($pad))
          + "\(glyphBar) "
          + "\(percentLeft)% "
          + resetPanel(.resetsAt)
        )
    end;

def laneLabel:
  if (.title? // null) != null then .title
  elif (.windowMinutes // 0) == 300 then "5h"
  elif (.windowMinutes // 0) == 10080 then "Weekly"
  elif ((.windowMinutes // 0) >= 40000 and (.windowMinutes // 0) <= 45000) then "Monthly"
  elif (.windowMinutes // null) != null then "\(.windowMinutes)m"
  else "Limit"
  end;

def laneLine:
  "  \(laneLabel): "
  + (if .usedPercent != null then "\(percentLeft)% left" else "usage unknown" end)
  + ", " + resetLong(.resetsAt);

def detailBlock($label):
  bindingLane as $b
  | [ "\($label): "
      + (if $b == null then "usage unavailable"
         else "\($b | percentLeft)% left, \(resetShort($b.resetsAt)) till reset"
         end),
      (if (.usage.accountEmail? // null) != null then "  Account: \(.usage.accountEmail)" else empty end),
      (if (.source? // null) != null then "  Source: \(.source)" else empty end),
      ((lanes + extraLanes)
        | map(laneLine)
        | if length == 0 then ["  Usage unavailable"] else . end)[],
      (if (.usage.updatedAt? // null) != null
       then "  Updated: \(.usage.updatedAt | fromdateiso8601? // null | if . == null then "?" else strflocaltime("%b %-d, %H:%M") end)"
       else empty end)
    ]
  | join("\n");

def pick($slug):
  map(select(.provider == $slug)) | first;
JQ
)"

require_commands() {
    missing=()
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    [ "${#missing[@]}" -eq 0 ] && return 0

    echo "codexbar-panel: not on PATH: ${missing[*]}" >&2
    return 1
}

# Fetches one provider, preferring codexbar's own source selection and falling
# back to its CLI reader. Returns non-zero if neither yields a usable window,
# so callers can render a placeholder row rather than nothing.
fetch_provider() {
    slug="$1"
    json=""

    for source in auto cli; do
        set +e
        candidate="$(timeout "$FETCH_TIMEOUT" codexbar usage \
            --provider "$slug" --source "$source" --format json --no-color 2>/dev/null)"
        set -e

        if [ -n "$candidate" ] && jq -e --arg slug "$slug" "$JQ_DEFS"'
            pick($slug) as $p
            | ($p != null) and (($p | lanes | length) > 0)
        ' <<<"$candidate" >/dev/null 2>&1; then
            json="$candidate"
            break
        fi
    done

    [ -n "$json" ] || return 1
    printf '%s\n' "$json"
}
detail_from_json() {
    local label="$1"
    local slug="$2"
    local json="$3"

    jq -r --arg label "$label" --arg slug "$slug" "$JQ_DEFS"'
        pick($slug) | detailBlock($label)
    ' <<<"$json" 2>/dev/null ||
        printf '%s: usage unavailable\n' "$label"
}

write_details_cache() {
    local content="$1"
    local cache_dir tmp_file

    cache_dir="$(dirname -- "$CACHE_FILE")"
    mkdir -p -- "$cache_dir" || return 0
    tmp_file="$(mktemp --tmpdir="$cache_dir" .details.XXXXXX)" || return 0
    printf '%s\n' "$content" >"$tmp_file" || {
        rm -f -- "$tmp_file"
        return 0
    }
    mv -f -- "$tmp_file" "$CACHE_FILE" || rm -f -- "$tmp_file"
}

read_details_cache() {
    [ -s "$CACHE_FILE" ] || return 1
    cat -- "$CACHE_FILE"
}

join_detail_blocks() {
    printf '%s\n\n' "$@" | sed '$d'
}

pad_panel_cell() {
    local cell="$1"
    local width
    local padding

    width="$(jq -rn --arg value "$cell" '$value | length')"
    padding=$((CELL_WIDTH - width))

    if [ "$padding" -gt 0 ]; then
        printf '%s%*s' "$cell" "$padding" ''
    else
        printf '%s' "$cell"
    fi
}

print_panel() {
    local left_rows=()
    local right_rows=()
    local provider_rows=()
    local detail_blocks=()
    local entry slug short detail json rendered detail_text

    for entry in "${PROVIDERS[@]}"; do
        IFS=: read -r slug short detail <<<"$entry"

        if json="$(fetch_provider "$slug")"; then
            if rendered="$(jq -r --arg label "$short" --arg slug "$slug" --argjson pad "$PAD_WIDTH" \
                "$JQ_DEFS"'
                pick($slug) | panelRows($label; $pad)[]
            ' <<<"$json" 2>/dev/null)" && [ -n "$rendered" ]; then
                mapfile -t provider_rows <<<"$rendered"
            else
                provider_rows=("$(printf "%-${PAD_WIDTH}s%s" "$short" "usage unavailable")")
            fi
            detail_text="$(detail_from_json "$detail" "$slug" "$json")"
        else
            provider_rows=("$(printf "%-${PAD_WIDTH}s%s" "$short" "usage unavailable")")
            detail_text="$detail: usage unavailable"
        fi

        detail_blocks+=("$detail_text")

        if [ "$slug" = "claude" ]; then
            right_rows+=("${provider_rows[@]}")
        else
            left_rows+=("${provider_rows[@]}")
        fi
    done

    local row_count="${#left_rows[@]}"
    if [ "${#right_rows[@]}" -gt "$row_count" ]; then
        row_count="${#right_rows[@]}"
    fi

    for ((i = 0; i < row_count; i += 1)); do
        if [ "$i" -lt "${#left_rows[@]}" ] && [ "$i" -lt "${#right_rows[@]}" ]; then
            printf '%s   %s\n' "$(pad_panel_cell "${left_rows[$i]}")" "${right_rows[$i]}"
        elif [ "$i" -lt "${#left_rows[@]}" ]; then
            printf '%s\n' "${left_rows[$i]}"
        else
            printf '%*s   %s\n' "$CELL_WIDTH" '' "${right_rows[$i]}"
        fi
    done

    write_details_cache "$(join_detail_blocks "${detail_blocks[@]}")"
}

print_details() {
    local separator=""
    local detail_blocks=()
    local entry slug detail json detail_text

    for entry in "${PROVIDERS[@]}"; do
        IFS=: read -r slug _short detail <<<"$entry"

        if json="$(fetch_provider "$slug")"; then
            detail_text="$(detail_from_json "$detail" "$slug" "$json")"
        else
            detail_text="$detail: usage unavailable"
        fi

        detail_blocks+=("$detail_text")
        printf '%s%s' "$separator" "$detail_text"
        separator=$'\n\n'
    done

    write_details_cache "$(join_detail_blocks "${detail_blocks[@]}")"
}

show_popup() {
    require_commands kdialog || exit 1

    details_file="$(mktemp --tmpdir codexbar-panel.XXXXXX)"
    trap 'rm -f "$details_file"' EXIT

    if ! read_details_cache >"$details_file"; then
        require_commands codexbar jq || exit 1
        print_details >"$details_file"
    fi

    kdialog --title "AI Usage Limits" --textbox "$details_file" 560 400 || true
}


main() {
    case "${1-}" in
    "")
        # A panel widget renders an empty result as a blank widget, so a
        # missing dependency is reported as rows rather than only on stderr.
        if ! require_commands codexbar jq; then
            for entry in "${PROVIDERS[@]}"; do
                IFS=: read -r _slug short _detail <<<"$entry"
                printf "%-${PAD_WIDTH}s%s\n" "$short" "missing: ${missing[*]}"
            done
            exit 0
        fi
        print_panel
        ;;
    --details)
        require_commands codexbar jq || exit 1
        print_details
        ;;
    --popup)
        show_popup
        ;;
    -h | --help)
        sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        ;;
    *)
        echo "Usage: codexbar-panel [--details|--popup]" >&2
        exit 2
        ;;
    esac
}

main "$@"
