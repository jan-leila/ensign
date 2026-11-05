{
  description = "Development shell for the Ensign FTL: Faster Than Light mod";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
        f (import nixpkgs { inherit system; config.allowUnfree = true; }));
    in {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            # C/C++ toolchain (gcc from stdenv)
            gnumake
            cmake
            pkg-config
            binutils
            gdb
            patchelf
            zig  # portable build: glibc-version-targeted cross compile

            # Lua
            lua5_3
            lua53Packages.luacheck

            python3

            # FTL mod manager
            slipstream

            # Utilities
            zip
            unzip
            git
            jq
            imagemagick
            unixtools.xxd
            file

            # headless smoke tests
            xvfb-run
            steam-run
            xwd
            mesa
            libglvnd
          ];

          shellHook = ''
            if [ -z "''${FTL_DIR:-}" ] && [ -d "$HOME/.steam/steam/steamapps/common/FTL Faster Than Light" ]; then
              export FTL_DIR="$HOME/.steam/steam/steamapps/common/FTL Faster Than Light"
            fi
            echo "ensign devshell: gcc cmake make gdb lua5.3 luacheck python3 slipstream zip jq imagemagick xxd"
          '';
        };
      });
    };
}
