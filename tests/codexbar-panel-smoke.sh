#!/usr/bin/env bash
# Renders codexbar-panel against stubbed codexbar output, so the row format and
# the failure paths are covered without touching the network or a real account.
set -euo pipefail
trap 'echo "failed: line $LINENO: $BASH_COMMAND" >&2' ERR

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$ROOT_DIR/codexbar-panel.sh"

# Invoked through bash rather than executed directly: the Nix build sandbox has
# no /usr/bin/env, and writeShellApplication replaces the shebang anyway.
run_script() {
    bash "$SCRIPT" "$@"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

STUB_DIR="$TMP_DIR/fixtures"
BIN_DIR="$TMP_DIR/bin"
mkdir -p -- "$STUB_DIR" "$BIN_DIR"

failures=0

# A stub codexbar that echoes a fixture chosen by --provider, and fails when no
# fixture exists. Uses /bin/sh because the Nix sandbox has no /usr/bin/env.
cat >"$BIN_DIR/codexbar" <<'STUB'
#!/bin/sh
set -eu
provider=""
while [ $# -gt 0 ]; do
  case "$1" in
    --provider) provider="${2-}"; shift 2 ;;
    *) shift ;;
  esac
done
fixture="$CODEXBAR_STUB_DIR/$provider.json"
[ -f "$fixture" ] || exit 1
cat -- "$fixture"
STUB
chmod +x -- "$BIN_DIR/codexbar"

export CODEXBAR_STUB_DIR="$STUB_DIR"
export PATH="$BIN_DIR:$PATH"

# ISO-8601 timestamp $1 seconds from now, so expected durations are stable.
at_offset() {
    date -u -d "@$(($(date +%s) + $1))" +%Y-%m-%dT%H:%M:%SZ
}

window() {
    jq -n --argjson used "$1" --argjson minutes "$2" --arg resets "$3" \
        '{usedPercent: $used, windowMinutes: $minutes, resetsAt: $resets}'
}

write_fixture() {
    provider="$1"
    shift
    jq -n --arg provider "$provider" --argjson usage "$1" \
        '[{provider: $provider, source: "stub", usage: $usage}]' \
        >"$STUB_DIR/$provider.json"
}

expect_eq() {
    name="$1"
    expected="$2"
    actual="$3"

    if [ "$expected" = "$actual" ]; then
        printf 'ok   %s\n' "$name"
    else
        printf 'FAIL %s\n' "$name" >&2
        printf '  expected:\n%s\n  actual:\n%s\n' "$expected" "$actual" >&2
        failures=$((failures + 1))
    fi
}

expect_match() {
    name="$1"
    pattern="$2"
    actual="$3"

    if grep -qE "$pattern" <<<"$actual"; then
        printf 'ok   %s\n' "$name"
    else
        printf 'FAIL %s\n' "$name" >&2
        printf '  pattern: %s\n  actual:\n%s\n' "$pattern" "$actual" >&2
        failures=$((failures + 1))
    fi
}

# --- one row per rate window, shortest first, values in a fixed column ------

write_fixture codex "$(jq -n \
    --argjson secondary "$(window 44 10080 "$(at_offset $((3 * 86400 + 21 * 3600 + 120)))")" \
    '{primary: null, secondary: $secondary, tertiary: null}')"

write_fixture claude "$(jq -n \
    --argjson primary "$(window 30 300 "$(at_offset $((3 * 3600 + 51 * 60 + 30)))")" \
    --argjson secondary "$(window 4 10080 "$(at_offset $((2 * 86400 + 3600 + 120)))")" \
    '{primary: $primary, secondary: $secondary, tertiary: null}')"

expect_eq "panel renders one row per window" \
    "Codex wk   56% left, 3d 21h till reset
Claude 5h  70% left, 3h 51m till reset
Claude wk  96% left, 2d 1h till reset" \
    "$(run_script)"

# Every row must put its percentage at the same column, or the values will not
# line up in the widget. A digit inside a label (the "5h" window) means this
# has to be anchored on the width, not on the first digit found.
expect_eq "values start at a fixed column" \
    "3" \
    "$(run_script | grep -cE '^.{11}[0-9]+% left,')"

# --- a provider with no usable window still yields exactly one row ----------

write_fixture claude '{"primary": null, "secondary": null, "tertiary": null}'

expect_eq "provider with no windows yields one row" \
    "Codex wk   56% left, 3d 21h till reset
Claude     usage unavailable" \
    "$(run_script)"

# --- a provider that cannot be fetched at all still yields exactly one row ---

rm -f -- "$STUB_DIR/claude.json"

expect_eq "unfetchable provider yields one row" \
    "Codex wk   56% left, 3d 21h till reset
Claude     usage unavailable" \
    "$(run_script)"

# --- unparseable and elapsed reset timestamps degrade, never error -----------

write_fixture claude "$(jq -n \
    --argjson primary "$(window 30 300 "not-a-timestamp")" \
    --argjson secondary "$(window 4 10080 "$(at_offset -3600)")" \
    '{primary: $primary, secondary: $secondary, tertiary: null}')"

expect_match "unparseable timestamp reads as unknown" \
    '^Claude 5h  70% left, reset unknown$' \
    "$(run_script)"

expect_match "elapsed window reads as zero" \
    '^Claude wk  96% left, 0m till reset$' \
    "$(run_script)"

# --- the widget must never be handed an empty result ------------------------

rm -f -- "$STUB_DIR"/*.json

expect_eq "no data at all still yields one row per provider" \
    "Codex      usage unavailable
Claude     usage unavailable" \
    "$(run_script)"

expect_eq "exit status stays zero when every provider fails" \
    "0" \
    "$(
        run_script >/dev/null 2>&1
        echo $?
    )"

# --- detail view covers both providers --------------------------------------

write_fixture codex "$(jq -n \
    --argjson secondary "$(window 44 10080 "$(at_offset $((3 * 86400 + 21 * 3600 + 120)))")" \
    '{primary: null, secondary: $secondary, tertiary: null}')"

expect_match "detail view names both providers" \
    '^Claude Code: usage unavailable$' \
    "$(run_script --details)"

expect_match "detail view lists the window" \
    '^  Weekly: 56% left, resets in 3d 21h' \
    "$(run_script --details)"

# --- usage errors ----------------------------------------------------------

expect_eq "unknown argument exits 2" \
    "2" \
    "$(
        run_script --nope >/dev/null 2>&1
        echo $?
    )"

if [ "$failures" -ne 0 ]; then
    printf '\n%d check(s) failed\n' "$failures" >&2
    exit 1
fi

printf '\nall checks passed\n'
