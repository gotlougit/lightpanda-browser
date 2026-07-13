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
      nixpkgs,
      zigPkgs,
      zlsPkg,
      fenix,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
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

        # We need crtbeginS.o for building.
        crtFiles = pkgs.runCommand "crt-files" { } ''
          mkdir -p $out/lib
          cp -r ${pkgs.gcc.cc}/lib/gcc $out/lib/gcc
        '';

        # V8 versions — kept in sync with .github/actions/install/action.yml
        v8Version = "14.9.207.35";
        zigV8Tag = "v0.5.1";

        # Map Nix system to the V8 archive naming convention used by the
        # zig-v8-fork releases:  libc_v8_<v8>_<os>_<arch>.a
        v8SystemMap = {
          x86_64-linux   = { os = "linux"; arch = "x86_64"; };
          aarch64-linux  = { os = "linux"; arch = "aarch64"; };
          x86_64-darwin  = { os = "macos"; arch = "x86_64"; };
          aarch64-darwin = { os = "macos"; arch = "aarch64"; };
        };

        v8ArchiveName =
          let s = v8SystemMap.${system};
          in "libc_v8_${v8Version}_${s.os}_${s.arch}.a";

        # Prebuilt V8 hashes per platform.
        # To get the hash for a missing platform, run:
        #   nix build .#default 2>&1 | grep "hash mismatch" | tail -1
        # then copy the "got:" hash here.
        v8Hashes = {
          x86_64-linux   = "sha256-VSumGZDTCiFeKh7A5JWDmnJVWPGxg8x69XKR+q3FFzE=";
          aarch64-linux  = pkgs.lib.fakeHash;
          x86_64-darwin  = pkgs.lib.fakeHash;
          aarch64-darwin = pkgs.lib.fakeHash;
        };

        # Prebuilt V8 library — fetched instead of building from source.
        prebuiltV8 = pkgs.fetchurl {
          name = v8ArchiveName;
          url = "https://github.com/lightpanda-io/zig-v8-fork/releases/download/${zigV8Tag}/${v8ArchiveName}";
          hash = v8Hashes.${system};
        };

        # Pre-fetch all zig dependencies (from build.zig.zon) in a
        # fixed-output derivation so the main build has no network needs.
        # Run `nix build .#zig-deps 2>&1 | grep "hash mismatch"` to update.
        zigDeps = pkgs.runCommand "lightpanda-zig-deps" {
          src = ./.;
          nativeBuildInputs = [ zig ];

          outputHashMode = "recursive";
          outputHash = "sha256-NW6CBFGtP2xjG3TkYAJn/wB/IMFSLGuGLq8tKhZUUcM=";

        } ''
          export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)

          # Copy the source tree so zig can read build.zig.zon.
          cp -r "$src" src
          chmod -R +w src
          cd src

          # Fetch all dependencies (including transitive ones).
          zig build --fetch=all

          # Keep only the fetched package content.
          mv "$ZIG_GLOBAL_CACHE_DIR"/p "$out"
        '';

        # Pre-fetch Rust crate dependencies for the html5ever component.
        # Update hash: nix build .#cargo-deps 2>&1 | grep "hash mismatch"
        cargoDeps = pkgs.runCommand "lightpanda-cargo-deps" {
          nativeBuildInputs = [ rustToolchain ];
          src = ./.;
          outputHashMode = "recursive";
          outputHash = "sha256-LHsM5pXlR8Zv2B1fRHm8/MPV42fEJ2TQWF9C8EPFVXo=";
        } ''
          export CARGO_HOME=$(mktemp -d)
          cd "$src"/src/html5ever
          cargo fetch --locked
          mv "$CARGO_HOME" "$out"
        '';

        # FHS build environment shared between the dev shell and the package
        # build.  The zig-v8-fork pipeline and C toolchain expect standard
        # FHS paths (/lib, /usr/lib, /usr/include) which Nix doesn't provide
        # by default.
        fhs = pkgs.buildFHSEnvBubblewrap {
          name = "kornel";
          targetPkgs =
            pkgs: with pkgs; [
              # Build tools
              zig
              zls
              rustToolchain
              python3
              pkg-config
              cmake
              gperf

              # GCC (provides crt files at standard paths)
              gcc
              gcc.cc.lib
              crtFiles

              # Libraries
              expat.dev
              glib.dev
              glibc.dev
              zlib
            ];
          runScript = "bash";
        };

        lightpanda = pkgs.stdenv.mkDerivation {
          name = "lightpanda-${v8Version}";
          src = ./.;

          nativeBuildInputs = [ fhs ];
          buildInputs = [ pkgs.cacert ];

          # Pre-fetched zig and cargo caches — symlink so the build
          # can find dependencies without network access.
          preBuild = ''
            export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
            ln -s ${zigDeps} "$ZIG_GLOBAL_CACHE_DIR"/p

            export CARGO_HOME=$(mktemp -d)
            ln -s ${cargoDeps}/registry "$CARGO_HOME"/registry
          '';

          buildPhase = ''
            runHook preBuild

            # Symlink the prebuilt V8 archive where zig-v8-fork expects it.
            mkdir -p v8
            ln -sf ${prebuiltV8} v8/libc_v8.a

            echo "=== Building V8 snapshot (release safe) ==="
            ${fhs}/bin/kornel -c '
              set -euo pipefail
              cd "'"$PWD"'"
              zig build -Doptimize=ReleaseFast \
                -Dprebuilt_v8_path=v8/libc_v8.a \
                snapshot_creator -- src/snapshot.bin
            '

            echo "=== Building lightpanda (release fast) ==="
            ${fhs}/bin/kornel -c '
              set -euo pipefail
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
        # Dev shell: enter the FHS environment interactively.
        devShells.default = fhs.env or fhs;

        # Standalone derivations that pre-fetch zig / cargo dependencies
        # (useful for debugging / updating the dep hashes).
        packages.zig-deps = zigDeps;
        packages.cargo-deps = cargoDeps;

        # Main package: the lightpanda binary.
        packages.default = lightpanda;
      }
    );
}
