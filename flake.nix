{
  description = "IFS/noglob convention checks plugin for ShellCheck (SC9001-SC9009)";

  inputs = {
    shellcheck = {
      url = "github:binaryphile/shellcheck";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, shellcheck, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        haskellPackages = pkgs.haskellPackages.override {
          overrides = hself: hsuper: {
            # Blanket doHaddock=false across the whole package set (dotfiles#112524):
            # the prior per-package `dontHaddock ShellCheck` below only stripped
            # ShellCheck's OWN doc output -- its transitive deps (assoc, colour,
            # prettyprinter, ansi-terminal, optparse-applicative, hashable, etc.)
            # and QuickCheck's deps still built full haddock docs by nixpkgs'
            # per-package default, since ghcWithPackages pulls them from this same
            # overridden set. Overriding mkDerivation itself applies to every
            # package built through this haskellPackages set, closing that gap.
            # Verified empirically: pkgs.haskellPackages.assoc.outputs == [out doc]
            # vs this override's assoc.outputs == [out] (dotfiles#112524 investigation).
            mkDerivation = args: hsuper.mkDerivation (args // { doHaddock = false; });
            ShellCheck = pkgs.haskell.lib.dontCheck (
              hself.callCabal2nix "ShellCheck" shellcheck {}
            );
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
                src/FragmentMode.hs \
                src/TaintSuffix.hs \
                src/MutualExclusive.hs \
                src/TaintAssignment.hs \
                src/UnnecessaryQuoting.hs \
                src/Numerics.hs \
                src/Inclusive.hs \
                src/Docstring.hs \
                src/ListInit.hs \
                src/ListsInit.hs \
                src/NilAvoidance.hs \
                src/IfsNoglobDiscipline.hs \
                src/SentinelLiteral.hs \
                src/SingleQuoteDefault.hs \
                src/OutParamNaming.hs \
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
