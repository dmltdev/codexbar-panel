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
# Panel output looks like this, padded so the values line up in a monospace
# font:
#
#   Codex wk   56% left, 3d 21h till reset
#   Claude 5h  70% left, 3h 51m till reset
#   Claude wk  96% left, 2d 1h till reset
#
# See README.md for requirements and for the Plasma widget settings.

set -euo pipefail

# "<codexbar provider slug>:<panel label>:<detail label>", in display order.
# The panel label is kept short because it repeats once per rate window; the
# detail view has room for the full name.
PROVIDERS=("codex:Codex:Codex" "claude:Claude:Claude Code" "grok:Grok:Grok")

# Column at which the values start. Shared by the jq padding and the shell
# fallbacks so the two cannot drift apart.
PAD_WIDTH="${CODEXBAR_PANEL_PAD_WIDTH:-11}"

# Panel widgets typically refresh on a timer that only restarts once this
# process exits, so an unbounded fetch would freeze the widget rather than
# just skip a cycle. Every codexbar call is bounded by this.
FETCH_TIMEOUT="${CODEXBAR_PANEL_TIMEOUT:-45}"

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

# Terse window name for the "<provider> <window>" row prefix.
def laneShort:
  if (.windowMinutes // 0) == 300 then "5h"
  elif (.windowMinutes // 0) == 10080 then "wk"
  elif ((.windowMinutes // 0) >= 40000 and (.windowMinutes // 0) <= 45000) then "mo"
  elif (.windowMinutes // null) != null then "\(.windowMinutes)m"
  else "--"
  end;

# Right-pads to a fixed column so the values line up. Needs a monospace font
# in the widget. In jq, string * 0 yields null rather than the empty string,
# but null is the identity for + on strings, so clamping at 0 is safe.
def padTo($n):
  . + (" " * ([$n - length, 0] | max));

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
          + "\(percentLeft)% left, "
          + (resetShort(.resetsAt)
             | if . == "?" then "reset unknown" else "\(.) till reset" end)
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

print_panel() {
    for entry in "${PROVIDERS[@]}"; do
        IFS=: read -r slug short _detail <<<"$entry"

        if json="$(fetch_provider "$slug")"; then
            jq -r --arg label "$short" --arg slug "$slug" --argjson pad "$PAD_WIDTH" \
                "$JQ_DEFS"'
                pick($slug) | panelRows($label; $pad)[]
            ' <<<"$json" 2>/dev/null ||
                printf "%-${PAD_WIDTH}s%s\n" "$short" "usage unavailable"
        else
            printf "%-${PAD_WIDTH}s%s\n" "$short" "usage unavailable"
        fi
    done
}

print_details() {
    separator=""

    for entry in "${PROVIDERS[@]}"; do
        IFS=: read -r slug _short detail <<<"$entry"

        printf '%s' "$separator"
        separator=$'\n'

        if json="$(fetch_provider "$slug")"; then
            jq -r --arg label "$detail" --arg slug "$slug" "$JQ_DEFS"'
                pick($slug) | detailBlock($label)
            ' <<<"$json" 2>/dev/null ||
                printf '%s: usage unavailable\n' "$detail"
        else
            printf '%s: usage unavailable\n' "$detail"
        fi
    done
}

show_popup() {
    require_commands kdialog || exit 1

    details_file="$(mktemp --tmpdir codexbar-panel.XXXXXX)"
    trap 'rm -f "$details_file"' EXIT

    print_details >"$details_file"
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
        require_commands codexbar jq || exit 1
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
