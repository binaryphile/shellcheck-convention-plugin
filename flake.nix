{
  description = "IFS/noglob convention checks plugin for ShellCheck (SC9001-SC9004)";

  inputs = {
    shellcheck.url = "github:binaryphile/shellcheck";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, shellcheck, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        haskellPackages = pkgs.haskellPackages.override {
          overrides = hself: hsuper: {
            ShellCheck = hself.callCabal2nix "ShellCheck" shellcheck {};
          };
        };
        ghc = haskellPackages.ghcWithPackages (p: [ p.ShellCheck p.QuickCheck ]);
      in {
        packages = {
          default = pkgs.stdenv.mkDerivation {
            name = "shellcheck-convention-plugin";
            src = ./.;
            buildInputs = [ ghc ];
            buildPhase = ''
              ghc -dynamic -shared -fPIC \
                -isrc \
                src/Convention.hs \
                src/TaintSuffix.hs \
                src/MutualExclusive.hs \
                src/TaintAssignment.hs \
                src/UnnecessaryQuoting.hs \
                src/Numerics.hs \
                src/Inclusive.hs \
                src/Plugin.hs \
                -o libconvention-checks.so \
                -no-hs-main
            '';
            installPhase = ''
              mkdir -p $out/lib/shellcheck/plugins
              cp libconvention-checks.so $out/lib/shellcheck/plugins/
            '';
          };
          shellcheck = haskellPackages.ShellCheck;
        };
      });
}
