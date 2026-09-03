# codexbar-panel

`codexbar-panel` renders AI coding-assistant usage limits as fixed-width rows,
one row per rate window:

```
Codex wk   56% left, 3d 21h till reset
Claude 5h  70% left, 3h 51m till reset
Claude wk  96% left, 2d 1h till reset
```

It is the backing command for a desktop panel widget — originally the KDE Plasma
[Command Output](https://github.com/Zren/plasma-applet-commandoutput) plasmoid —
but it is a plain script that writes to stdout, so anything that can run a
command and display its output will work.

Usage data comes from [CodexBar](https://github.com/steipete/CodexBar)'s CLI,
which is what knows how to talk to each provider.

## Why one row per window

Providers publish more than one rate window and they do not agree on which.
Codex publishes a weekly window; Claude publishes a 5-hour window and a weekly
one. Collapsing that into a single number per provider means the row silently
switches between windows as usage shifts, and nothing on screen says which
window you are looking at. One row per window keeps every row meaning exactly
one thing, and lanes appearing or disappearing adds or removes rows rather than
changing what a row means.

Provider-specific extra windows (Codex Spark, for instance) are deliberately
kept out of the panel and shown only in the detail view, so the panel row count
stays predictable.

## Requirements

- [`codexbar`](https://github.com/steipete/CodexBar) — the CodexBar CLI, on `PATH`
- `jq` 1.6 or newer, for `strflocaltime`
- `timeout`, `date`, `mktemp`, `printf` from coreutils
- `kdialog`, only for `--popup`

## Usage

```bash
codexbar-panel            # one row per rate window, for a panel widget
codexbar-panel --details  # multi-line per-provider detail, for a tooltip
codexbar-panel --popup    # the same detail in a kdialog textbox
codexbar-panel --help
```

Environment overrides:

| Variable                       | Default | Purpose                                        |
| ------------------------------ | ------- | ---------------------------------------------- |
| `CODEXBAR_PANEL_TIMEOUT`       | `45`    | Seconds allowed per `codexbar` fetch           |
| `CODEXBAR_PANEL_PAD_WIDTH`     | `11`    | Column at which the values start               |

To change which providers are shown, edit the `PROVIDERS` array at the top of
the script. Entries are `<codexbar provider slug>:<panel label>:<detail label>`.

## Install

### Any distribution

Drop the script somewhere on `PATH` and make sure the requirements above are
installed:

```bash
install -m 0755 codexbar-panel.sh ~/.local/bin/codexbar-panel
```

### NixOS

The flake exposes `packages.default`. Pass your own `codexbar` derivation to
bind it hermetically, since CodexBar is not in nixpkgs:

```nix
{
  inputs.codexbar-panel.url = "github:dmltdev/codexbar-panel";

  # ...
  environment.systemPackages = [
    (inputs.codexbar-panel.packages.${pkgs.system}.default.override {
      codexbarCli = codexbar;
    })
  ];
}
```

Leave the override off and the script resolves `codexbar` from `PATH` instead.

## Plasma widget settings

Add a Command Output widget to a panel and set, under its configuration:

| Setting            | Value                    |
| ------------------ | ------------------------ |
| Command            | `codexbar-panel`         |
| Click command      | `codexbar-panel --popup` |
| Interval           | `180000` (3 minutes)     |
| Wait for command   | enabled                  |
| Font size          | `8`                      |
| Font family        | `monospace`              |

The font must be monospace or the value columns will not line up. Three rows at
8pt fit a 46px panel without clipping.

`Wait for command` matters: with it enabled the widget's refresh timer only
restarts once the process exits, so a hung fetch would freeze the widget rather
than skip a cycle. Every `codexbar` call is therefore bounded by
`CODEXBAR_PANEL_TIMEOUT`.

## Behaviour under failure

A panel widget renders an empty result as a blank widget, which reads as broken
rather than as degraded. So the script prints exactly one row per provider on
every path and exits `0`:

| Situation                          | Row                                    |
| ---------------------------------- | -------------------------------------- |
| Provider cannot be fetched         | `Claude     usage unavailable`         |
| Provider reports no usable window  | `Claude     usage unavailable`         |
| `codexbar` or `jq` not on `PATH`   | `Claude     missing: codexbar`         |
| Reset timestamp will not parse     | `Claude 5h  70% left, reset unknown`   |

Reset times are always computed from the machine-readable `resetsAt` field,
never from a provider's own `resetDescription` — Claude returns that with the
spaces stripped, e.g. `Resets5:30pm(Europe/Sofia)`. Percentages are floored and
clamped to 0–100 so headroom is never overstated.

## Development

```bash
nix develop            # jq, shellcheck, shfmt
nix flake check        # runs the smoke tests
bash tests/codexbar-panel-smoke.sh
```

The tests stub `codexbar` with fixtures, so they need no network and no
provider account.

The jq program lives in a `JQ_DEFS` quoted heredoc and is concatenated with a
short single-quoted expression at each call site. Keep those call-site
expressions free of apostrophes — one would close the shell quote and spill jq
into bash.

## License

MIT
