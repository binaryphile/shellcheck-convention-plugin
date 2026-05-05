{
  description = "IFS/noglob convention checks plugin for ShellCheck (SC9001-SC9004)";

  inputs = {
    shellcheck.url = "github:binaryphile/shellcheck/dynamic-plugin-loading";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, shellcheck, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        scPkg = shellcheck.packages.${system}.lib;
        ghc = pkgs.haskellPackages.ghcWithPackages (p: [ scPkg ]);
      in {
        packages.default = pkgs.stdenv.mkDerivation {
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
              src/Plugin.hs \
              -o libconvention-checks.so \
              -main-is Plugin
          '';
          installPhase = ''
            mkdir -p $out/lib/shellcheck/plugins
            cp libconvention-checks.so $out/lib/shellcheck/plugins/
          '';
        };
      });
}
