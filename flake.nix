{
  description = "csw - switch between Claude Code and Claude Desktop accounts";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    let
      lib = nixpkgs.lib;
      zonLines = lib.splitString "\n" (builtins.readFile ./build.zig.zon);
      versionLine = lib.findFirst (line: lib.hasInfix ".version = " line) "" zonLines;
      version = builtins.head (builtins.match ''.*"([^"]+)".*'' versionLine);

      muslTarget = {
        x86_64-linux = "x86_64-linux-musl";
        aarch64-linux = "aarch64-linux-musl";
      };

      mkCsw = { pkgs, zig }:
        let
          target = muslTarget.${pkgs.stdenv.hostPlatform.system} or null;
        in
        pkgs.stdenv.mkDerivation {
          pname = "csw";
          inherit version;
          src = lib.cleanSource ./.;

          nativeBuildInputs = [ zig pkgs.pkg-config pkgs.installShellFiles ];
          buildInputs = [ pkgs.sqlite ];

          dontConfigure = true;
          dontInstall = true;

          buildPhase = ''
            runHook preBuild
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-global-cache
            zig build -Doptimize=ReleaseSmall --prefix $out --cache-dir $TMPDIR/zig-cache \
              --search-prefix ${pkgs.sqlite.dev} --search-prefix ${pkgs.sqlite.out} \
              ${lib.optionalString (target != null) "-Dtarget=${target}"}
            installShellCompletion --cmd csw \
              --bash <($out/bin/csw completion bash) \
              --zsh <($out/bin/csw completion zsh) \
              --fish <($out/bin/csw completion fish)
            $out/bin/csw man > csw.1
            installManPage csw.1
            runHook postBuild
          '';

          meta = {
            description = "Switch between Claude Code and Claude Desktop accounts";
            homepage = "https://github.com/mtxr/claude-switch";
            license = lib.licenses.mit;
            mainProgram = "csw";
            platforms = lib.platforms.darwin ++ lib.platforms.linux;
          };
        };

      mkTests = { pkgs, zig }:
        pkgs.stdenv.mkDerivation {
          pname = "csw-tests";
          inherit version;
          src = lib.cleanSource ./.;
          nativeBuildInputs = [ zig pkgs.pkg-config ];
          buildInputs = [ pkgs.sqlite ];
          dontConfigure = true;
          dontInstall = true;
          buildPhase = ''
            export HOME=$TMPDIR
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-global-cache
            zig build test --cache-dir $TMPDIR/zig-cache
            touch $out
          '';
        };

      zigFor = system: zig-overlay.packages.${system}."0.17.0";
    in
    {
      overlays.default = final: prev: {
        csw = mkCsw {
          pkgs = final;
          zig = zigFor final.stdenv.hostPlatform.system;
        };
      };
    }
    // flake-utils.lib.eachSystem [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = zigFor system;
        csw = mkCsw { inherit pkgs zig; };
      in
      {
        packages = {
          inherit csw;
          default = csw;
        };

        apps.default = {
          type = "app";
          program = "${csw}/bin/csw";
          meta = csw.meta;
        };

        devShells.default = pkgs.mkShell {
          packages = [ zig pkgs.skim pkgs.fzf pkgs.sqlite pkgs.pkg-config ];
        };

        checks = {
          inherit csw;
        } // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
          tests = mkTests { inherit pkgs zig; };
        };
      });
}
