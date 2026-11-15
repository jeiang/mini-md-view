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
      # The Zig packages from build.zig.zon: tree-sitter and its grammars. Update the hash when
      # the dependencies change. The default fetch skips the lazy dependencies of the packages,
      # which the build does not use.
      depsFor =
        pkgs:
        pkgs.stdenvNoCC.mkDerivation {
          name = "mini-md-view-zig-deps";
          src = self;
          nativeBuildInputs = [ pkgs.zig ];
          dontConfigure = true;
          dontFixup = true;
          buildPhase = ''
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
            zig build --fetch
          '';
          installPhase = "cp -r zig-pkg $out";
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          outputHash = "sha256-ybwRuDdgRDwxOVN+tCwfBQYl5qROw7CPTt2uMXBaJek=";
        };
    in
    {
      packages = forAllSystems (pkgs: rec {
        mini-md-view = pkgs.stdenv.mkDerivation {
          pname = "mini-md-view";
          version = "0.0.0";
          src = self;
          nativeBuildInputs = [ pkgs.zig.hook ];
          preBuild = ''
            cp -r ${depsFor pkgs} zig-pkg
            chmod -R u+w zig-pkg
          '';
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
