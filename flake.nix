{
  description = "headless browser designed for AI and automation";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

    zigPkgs.url = "github:mitchellh/zig-overlay";
    zigPkgs.inputs.nixpkgs.follows = "nixpkgs";

    zlsPkg.url = "github:zigtools/zls/0.15.0";
    zlsPkg.inputs.zig-overlay.follows = "zigPkgs";
    zlsPkg.inputs.nixpkgs.follows = "nixpkgs";

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      zigPkgs,
      zlsPkg,
      fenix,
      flake-utils,
      ...
    }:
    let
      forEachSystem = flake-utils.lib.eachDefaultSystem (
        system:
        let
          overlays = [
            (final: prev: {
              zigpkgs = zigPkgs.packages.${prev.system};
              zls = zlsPkg.packages.${prev.system}.default;
            })
          ];

          pkgs = import nixpkgs {
            inherit system overlays;
          };

          zig = pkgs.zigpkgs."0.15.2";

          rustToolchain = fenix.packages.${system}.stable.toolchain;

          # V8 versions — kept in sync with .github/actions/install/action.yml
          v8Version = "14.9.207.35";
          zigV8Tag = "v0.5.1";

          # Map Nix system to the V8 archive naming convention used by the
          # zig-v8-fork releases:  libc_v8_<v8>_<os>_<arch>.a
          v8SystemMap = {
            x86_64-linux = {
              os = "linux";
              arch = "x86_64";
            };
            aarch64-linux = {
              os = "linux";
              arch = "aarch64";
            };
            x86_64-darwin = {
              os = "macos";
              arch = "x86_64";
            };
            aarch64-darwin = {
              os = "macos";
              arch = "aarch64";
            };
          };

          v8ArchiveName =
            let
              s = v8SystemMap.${system};
            in
            "libc_v8_${v8Version}_${s.os}_${s.arch}.a";

          # Prebuilt V8 hashes per platform.
          v8Hashes = {
            x86_64-linux = "sha256-VSumGZDTCiFeKh7A5JWDmnJVWPGxg8x69XKR+q3FFzE=";
            aarch64-linux = pkgs.lib.fakeHash;
            x86_64-darwin = pkgs.lib.fakeHash;
            aarch64-darwin = pkgs.lib.fakeHash;
          };

          # Prebuilt V8 library — fetched instead of building from source.
          prebuiltV8 = pkgs.fetchurl {
            name = v8ArchiveName;
            url = "https://github.com/lightpanda-io/zig-v8-fork/releases/download/${zigV8Tag}/${v8ArchiveName}";
            hash = v8Hashes.${system};
          };

          # Pre-fetched zig dependencies via linkFarm.
          # Generated from build.zig.zon by zon2nix.
          # To regenerate: nix run nixpkgs#zon2nix -- build.zig.zon > deps.nix
          zigDeps = pkgs.callPackage ./deps.nix { };

          # Pre-fetch Rust crate dependencies for the html5ever component.
          cargoDeps =
            pkgs.runCommand "lightpanda-cargo-deps"
              {
                nativeBuildInputs = [ rustToolchain ];
                src = ./.;
                outputHashMode = "recursive";
                outputHash = "sha256-LHsM5pXlR8Zv2B1fRHm8/MPV42fEJ2TQWF9C8EPFVXo=";
              }
              ''
                export CARGO_HOME=$(mktemp -d)
                cd "$src"/src/html5ever
                cargo fetch --locked
                mv "$CARGO_HOME" "$out"
              '';

          # FHS build environment that provides /usr/lib, /usr/include
          # and the dynamic linker — paths the zig C / C++ toolchain expects
          # on a glibc-based Linux distribution.
          fhs = pkgs.buildFHSEnvBubblewrap {
            name = "kornel";
            targetPkgs =
              pkgs: with pkgs; [
                zig
                zls
                rustToolchain
                python3
                pkg-config
                cmake
                gperf
                gcc
                gcc.cc.lib
                expat.dev
                glib.dev
                glibc.dev
                glibc
                zlib
              ];
            runScript = "bash";
          };

          lightpanda = pkgs.stdenv.mkDerivation {
            name = "lightpanda-${v8Version}";
            src = ./.;

            nativeBuildInputs = [ fhs ];
            buildInputs = [ pkgs.cacert ];

            dontUseCmakeConfigure = true;

            # Pre-fetched cargo cache for the html5ever Rust component.
            preBuild = ''
              export CARGO_HOME=$(mktemp -d)
              ln -s ${cargoDeps}/registry "$CARGO_HOME"/registry
            '';

            buildPhase = ''
              runHook preBuild

              # Symlink the prebuilt V8 archive where zig-v8-fork expects it.
              mkdir -p v8
              ln -sf ${prebuiltV8} v8/libc_v8.a

              # Populate the zig global cache with pre-fetched deps.
              export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
              mkdir -p "$ZIG_GLOBAL_CACHE_DIR"/p
              for _d in "${zigDeps}"/*; do
                ln -s "$(readlink "$_d")" "$ZIG_GLOBAL_CACHE_DIR/p/$(basename "$_d")"
              done

              echo "=== Building V8 snapshot (release safe) ==="
              ${fhs}/bin/kornel -c '
                set -euo pipefail
                export ZIG_GLOBAL_CACHE_DIR="'"$ZIG_GLOBAL_CACHE_DIR"'"
                export CARGO_HOME="'"$CARGO_HOME"'"
                cd "'"$PWD"'"
                zig build -Doptimize=ReleaseFast \
                  -Dprebuilt_v8_path=v8/libc_v8.a \
                  snapshot_creator -- src/snapshot.bin
              '

              echo "=== Building lightpanda (release fast) ==="
              ${fhs}/bin/kornel -c '
                set -euo pipefail
                export ZIG_GLOBAL_CACHE_DIR="'"$ZIG_GLOBAL_CACHE_DIR"'"
                export CARGO_HOME="'"$CARGO_HOME"'"
                cd "'"$PWD"'"
                zig build -Doptimize=ReleaseFast \
                  -Dsnapshot_path=../../snapshot.bin \
                  -Dprebuilt_v8_path=v8/libc_v8.a
              '

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              cp zig-out/bin/lightpanda $out/bin/
              runHook postInstall
            '';

            meta = {
              description = "Headless browser designed for AI and automation";
              homepage = "https://lightpanda.io";
              license = pkgs.lib.licenses.agpl3Only;
              mainProgram = "lightpanda";
              platforms = builtins.attrNames v8SystemMap;
            };
          };

        in
        {
          devShells.default = pkgs.mkShell {
            nativeBuildInputs = with pkgs; [
              zig
              zls
              rustToolchain
              python3
              python3Packages.playwright
              pkg-config
              cmake
              gperf
            ];

            buildInputs = with pkgs; [
              glibc.dev
              stdenv.cc.cc
              stdenv.cc.cc.lib
              gcc.cc.lib
            ];

            shellHook = ''
              export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global"
              export CARGO_HOME="$PWD/.cargo-home"
              mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$CARGO_HOME"

              mkdir -p .lp-cache/prebuilt-v8
              if [ ! -f ".lp-cache/prebuilt-v8/${v8ArchiveName}" ]; then
                ln -sf ${prebuiltV8} ".lp-cache/prebuilt-v8/${v8ArchiveName}"
              fi

              mkdir -p v8
              if [ ! -f v8/libc_v8.a ]; then
                ln -sf ${prebuiltV8} v8/libc_v8.a
              fi

              echo "=== Lightpanda dev shell ==="
              echo "  zig   : $(zig version)"
              echo "  v8    : ${v8Version} (prebuilt)"
              echo "  cache : $ZIG_GLOBAL_CACHE_DIR"
              echo ""
              echo "Quick start:"
              echo "  zig build -Dprebuilt_v8_path=v8/libc_v8.a                   # debug build"
              echo "  zig build -Dprebuilt_v8_path=v8/libc_v8.a test              # run tests"
              echo "  zig build -Doptimize=ReleaseFast -Dprebuilt_v8_path=v8/libc_v8.a  # release"
              echo "  make build-dev                                              # or use make"
            '';
          };

          packages.zig-deps = zigDeps;
          packages.cargo-deps = cargoDeps;
          packages.default = lightpanda;
        }
      );

    in
    forEachSystem
    // {
      nixosModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        {
          nixpkgs.overlays = [
            (final: prev: {
              lightpanda = self.packages.${pkgs.system}.default;
            })
          ];
          imports = [ ./modules/nixos/lightpanda.nix ];
        };
    };
}
