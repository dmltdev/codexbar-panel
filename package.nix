{
  lib,
  writeShellApplication,
  coreutils,
  jq,
  kdePackages,
  # The CodexBar CLI for Linux is not in nixpkgs. (nixpkgs does have a
  # `codexbar` attribute, but it is the macOS app and is marked
  # aarch64-darwin only, which is also why this argument is deliberately not
  # named `codexbar` - callPackage would auto-supply that one and it would
  # refuse to evaluate on Linux.)
  #
  # Pass your own derivation to bind the CLI hermetically, or leave it null
  # and the script will resolve `codexbar` from PATH at runtime, reporting a
  # row per provider if it is missing.
  codexbarCli ? null,
}:

writeShellApplication {
  name = "codexbar-panel";

  runtimeInputs = [
    coreutils
    jq
    kdePackages.kdialog
  ]
  ++ lib.optional (codexbarCli != null) codexbarCli;

  # The shebang in the script becomes a comment here, since
  # writeShellApplication supplies its own along with `set -euo pipefail`.
  text = builtins.readFile ./codexbar-panel.sh;

  meta = {
    description = "Render AI coding-assistant usage limits as desktop panel rows";
    homepage = "https://github.com/dmltdev/codexbar-panel";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "codexbar-panel";
  };
}
