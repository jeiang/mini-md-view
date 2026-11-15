{
  description = "mini-md-view";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        mini-md-view = pkgs.stdenv.mkDerivation {
          pname = "mini-md-view";
          version = "0.0.0";
          src = self;
          nativeBuildInputs = [ pkgs.zig.hook ];
          # AppKit enables Liquid Glass only for binaries linked against the macOS 26 SDK or newer.
          buildInputs = [ pkgs.apple-sdk_27 ];
          # nix-darwin links applications from $out/Applications.
          postInstall = ''
            mkdir -p $out/Applications
            mv $out/MiniMdView.app $out/Applications/
          '';
          meta.mainProgram = "mini-md-view";
        };
        default = mini-md-view;
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.zig
            pkgs.zls
          ];
          # AppKit enables Liquid Glass only for binaries linked against the macOS 26 SDK or newer.
          buildInputs = [ pkgs.apple-sdk_27 ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
