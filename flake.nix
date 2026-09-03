{
  description = "Render AI coding-assistant usage limits as desktop panel rows";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            inherit system;
            pkgs = nixpkgs.legacyPackages.${system};
          }
        );
    in
    {
      packages = forAllSystems (
        { pkgs, system }:
        {
          codexbar-panel = pkgs.callPackage ./package.nix { };
          default = self.packages.${system}.codexbar-panel;
        }
      );

      devShells = forAllSystems (
        { pkgs, ... }:
        {
          default = pkgs.mkShellNoCC {
            packages = [
              pkgs.jq
              pkgs.shellcheck
              pkgs.shfmt
            ];
          };
        }
      );

      checks = forAllSystems (
        { pkgs, system }:
        {
          package = self.packages.${system}.codexbar-panel;

          smoke =
            pkgs.runCommand "codexbar-panel-smoke"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.jq
                  pkgs.coreutils
                ];
              }
              ''
                cp -r ${./.} src
                chmod -R +w src
                bash src/tests/codexbar-panel-smoke.sh
                touch $out
              '';
        }
      );
    };
}
