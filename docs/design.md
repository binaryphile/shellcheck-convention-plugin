# Design: shellcheck-convention-plugin

Mechanism (HOW) for the IFS/noglob convention check plugin. WHAT lives
in [use-cases.md](use-cases.md); this document covers architecture,
the build/test surface, and the per-check catalog.

## 1. Architecture

The plugin is a single `libconvention-checks.so` shared library loaded
by `binaryphile/shellcheck` via `dlopen` at startup. The host plugin
ABI is documented in the fork's `docs/design.md` §1.6 ("Dynamic
Plugin Loading"). This plugin targets `pluginApiVersion = 2`.

### 1.1 Per-check module pattern

Every check lives in its own `src/<CheckName>.hs` module exporting a
single `check :: CustomCheck` value plus `runTests` for inline
`prop_` discovery. The pattern (concrete reference: `Inclusive.hs`):

```haskell
{-# LANGUAGE TemplateHaskell #-}
module <CheckName> (check, <CheckName>.runTests) where

import ShellCheck.AST
import ShellCheck.ASTLib
import ShellCheck.AnalyzerLib
import ShellCheck.Checks.Custom.Base
import ShellCheck.Interface
-- (optionally Convention for shared predicates)

import Test.QuickCheck.All (forAllProperties)
import Test.QuickCheck.Test (quickCheckWithResult, stdArgs, maxSuccess)

check :: CustomCheck
check = CustomCheck {
    ccChecker     = checkX,
    ccAlwaysOn    = False,    -- or True for always-on
    ccDescription = newCheckDescription {
        cdName        = "<opt-in-name>",
        cdDescription = "What this check enforces",
        cdPositive    = "<one-line bash that triggers>",
        cdNegative    = "<one-line bash that stays silent>"
    }
}

checkX :: Token -> Analysis
checkX (T_... ) = ...
checkX _ = return ()

-- inline prop_sc<N>_* tests using verify / verifyNot / verifyCode

return []
runTests = $(forAllProperties) (quickCheckWithResult (stdArgs { maxSuccess = 1 }))
```

### 1.2 Registry: `src/Plugin.hs`

The single source of truth for what's loaded. Each check imported
qualified and appended to the `plugin_init` list. The module-level
comment block enumerates SC codes — this is the operator-facing
authority on what the plugin ships. `foreign export` declarations
provide the dlopen ABI:

- `plugin_api_version :: IO CInt` returns
  `fromIntegral pluginApiVersion` (from `Checks.Custom.Base`).
- `plugin_init :: IO (StablePtr [CustomCheck])` returns a
  `newStablePtr` over the check list.

### 1.3 Shared helpers: `src/Convention.hs`

Domain helpers shared across multiple checks (currently SC9001 /
SC9004):

- `hasTaintSuffix :: String -> Bool` — name ends in `_` and is
  longer than 1 char (excludes the special `$_` variable).
- `stripTaintSuffix :: String -> String` — drops a trailing `_`.
- `hasListSuffix :: String -> Bool` — bare name (post-strip) ends
  in `List` or `List<X>` where X is a single uppercase ASCII letter
  (a library suffix marker, e.g. `hostListQ_`).

Extending this module is the right move when ≥ 2 checks need the
same predicate; for one-off predicates, inline them in the check
module.

### 1.4 Foreign-export ABI

The plugin uses `foreign export ccall` for both required symbols.
Build invocation must include `-shared -fPIC -no-hs-main`; see §2.
Plugins MUST NOT use `-flink-rts` (the host's RTS is shared via
`-rdynamic`).

## 2. Build and test surface

### 2.1 Nix flake

`nix build .#default` produces
`result/lib/shellcheck/plugins/libconvention-checks.so`. The flake's
`buildPhase` invokes `ghc -dynamic -shared -fPIC -isrc -no-hs-main`
listing each source file explicitly (so a new check requires updating
both `Plugin.hs` AND `flake.nix`).

`flake.lock` pins the host (`binaryphile/shellcheck`) to a specific
commit. Checks that use new `Base.hs` APIs must be paired with a
`nix flake update shellcheck` to bump the pin.

### 2.2 Per-module prop tests

Each `<CheckName>.hs` ends with:

```haskell
return []
runTests = $(forAllProperties) (quickCheckWithResult (stdArgs { maxSuccess = 1 }))
```

Currently `runTests` is exported but not invoked by the flake build
(which only links the `.so`). Tests run when the modules are
compiled by `cabal test` if a downstream consumer (the fork) wires
them in, or via interactive `ghci` for local development. For
end-to-end correctness coverage, see §2.3.

### 2.3 End-to-end gate: `bin/verify`

The contract gate. Builds the plugin and the host shellcheck (both
via nix), copies the `.so` into a temp plugin dir, runs shellcheck
with `--enable=all` against `test/positive.sh` and `test/negative.sh`,
and asserts:

1. Plugin logs `Loaded plugin: libconvention-checks.so (N check(s))`
   with N matching the registered count.
2. Every SC9xxx code in `codes=(...)` array appears on the positive
   fixture.
3. No SC9xxx code appears on the negative fixture.

Exit 0 with `OK: SC9001-SC<latest> emitted on positive, silent on
negative; dlopen confirmed` on success; non-zero with a `FAIL:` line
on the first failure.

Every check-add cycle bumps four things in lockstep: `codes` array,
"Loaded plugin" regex, final OK message, positive+negative fixtures.

## 3. Check catalog

H3 subsection per check. Source-rule citations point to
`~/projects/jeeves/guides/bash-style-guide.md` sections where the
mapping is direct; checks without a published source are tagged
"convention (project-local)".

### SC9001 — Unquoted tainted variable

- **Module**: `src/TaintSuffix.hs`
- **Severity**: `err`
- **Always-on**: yes
- **Source rule**: IFS/noglob discipline (project-local; bash-style-guide §3 discusses *_ taint suffix).
- **Pattern**: a `T_DollarBraced` whose name has the `_` taint
  suffix is expanded in a word-splitting context (unquoted) — must
  be quoted to prevent IFS splitting and glob expansion.
- **False-positive shape**: `for var_ in ...` (loop variables are
  context-controlled, not user-input); the check excludes
  `T_ForIn` ancestors.

### SC9002 — Command substitution taint

- **Module**: `src/TaintAssignment.hs`
- **Severity**: `warn`
- **Always-on**: no — `cdName = "taint-assignment"`
- **Source rule**: IFS/noglob discipline (project-local).
- **Pattern**: `x=$(cmd)` where `x` does NOT have the `_` taint
  suffix and `cmd` is not in the allowlisted-pure-output set
  (`hostname`, etc.). Cmdsub output may contain newlines; the
  taint-suffix convention requires capturing it into a `_`-suffixed
  variable.
- **False-positive shape**: allowlisted commands; intentional
  newline-stripped patterns.

### SC9003 — Unnecessary quoting under IFS/noglob

- **Module**: `src/UnnecessaryQuoting.hs`
- **Severity**: `style` (note)
- **Always-on**: no — `cdName = "unnecessary-quoting"`
- **Source rule**: IFS/noglob discipline (project-local; inverse
  of SC9001).
- **Pattern**: a non-taint variable expansion that's quoted in a
  splitting context where IFS+noglob makes the quoting redundant.
- **False-positive shape**: variables that legitimately could
  contain whitespace despite not having the taint suffix.

### SC9004 — Mutually exclusive suffixes

- **Module**: `src/MutualExclusive.hs`
- **Severity**: `err`
- **Always-on**: yes
- **Source rule**: project-local — taint convention says `_` and
  `List` cannot coexist on one identifier.
- **Pattern**: `T_Assignment` or expansion where the name has BOTH
  the `_` taint suffix and the `List` suffix (with optional
  single-uppercase library marker).
- **Notes**: The List/array distinction here pivots on a different
  question than SC9008's (reverted) — see SC9008 for the *List
  reconciliation.

### SC9005 — Numeric comparison in `[[ ]]` / `[ ]`

- **Module**: `src/Numerics.hs`
- **Severity**: `style` (note)
- **Always-on**: no — `cdName = "numerics-in-brackets"`
- **Source rule**: bash-style-guide §7 — prefer `(( x == N ))`
  over `[[ $x -eq N ]]` for integer comparisons.
- **Pattern**: `TC_Binary` with operator in
  `{-eq,-ne,-lt,-gt,-le,-ge}` inside any condition node.
- **False-positive shape**: none today; string/file/path tests use
  different operators and stay in `[[ ]]`.

### SC9006 — Legacy whitelist/blacklist in identifier or comment

- **Module**: `src/Inclusive.hs`
- **Severity**: `warn`
- **Always-on**: no — `cdName = "inclusive-language"`
- **Source rule**: inclusive-language convention (project-local).
- **Pattern**: case-insensitive substring `whitelist` or `blacklist`
  in:
  - **Identifier scope**: `T_Assignment` variable name, `T_Function`
    name.
  - **Comment scope**: `T_Comment` text (requires host
    `pluginApiVersion = 2` for the splice).
- **Replacement**: suggests `allowlist` / `denylist`.
- **False-positive shape**: expansions (`echo $whitelist`); loop
  variables; shellcheck directives (which bypass `T_Comment`).
- **Notes**: comment scope landed via tasks.shellcheck-convention-plugin
  task #7739 (commit f1f79e2), enabled by the T_Comment splice in
  upstream task #7469 (commit ddbd0c3).

### SC9007 — Docstring should begin with function name

- **Module**: `src/Docstring.hs`
- **Severity**: `style` (note)
- **Always-on**: no — `cdName = "docstring-shape"`
- **Source rule**: bash-style-guide §11 — function docstrings name
  the function as subject.
- **Pattern**: `T_Function` with a non-empty contiguous comment
  block immediately preceding it (via `getDocCommentsBefore`)
  whose first non-empty word after `#` is not the function name.
- **Strict equality**: case-sensitive, exact match. `the foo`
  fails; `foo - does X` matches.
- **False-positive shape**: section-header comments that happen to
  sit directly above a function. Workaround: blank-line separation
  between header and the function being documented.
- **Notes**: landed via task #7689 (commit 3077be2). First consumer
  of the T_Comment splice.

### SC9008 — REVERTED (list-init-shape misframe)

- **Status**: shipped 2026-05-18 (commit 5f353b7); **reverted** same
  day (commit 90fc758) on `main`. Plugin currently exports
  SC9001-SC9007 only.
- **What the reverted version did**: warned on `T_Assignment` where
  the variable name ended in `List`/`List<X>` and the value was not
  a `T_Array` literal. Implemented the umbrella task #6186 rule 5
  ("List-suffixed variables should be initialized as arrays") at
  face value.
- **Why it was wrong**: bash-style-guide §3 line 72 says `*List` is
  an **IFS-serialized string** (must-quote on expansion), not an
  array. Arrays use plural-noun suffix
  (`octopi=( inky blinky )`). The umbrella's rule 5 misframed
  the *List shape; the SC9008 implementation followed the misframe.
- **Reconciliation**: tasks.jeeves #6469 closed with Option A
  (§3 stands as written); task-done event #7937.
- **Supersede target**: task #7951 on this stream will re-implement
  SC9008 with the corrected rule (flag `*List = ( ... )` array
  literals; suggest plural-noun suffix). SC9008 code is renewable
  because the rule's *direction* was wrong, not its number-space.
- **Process lesson** (era memory `ce0e0fb50087`): when retro-claiming
  closure on an umbrella, read the cross-stream follow-up tasks in
  full — they often carry critical context that changes how "done"
  should be evaluated. The umbrella's wording alone is not
  sufficient.

## 4. Reference

- Host plugin system: `binaryphile/shellcheck` `docs/design.md` and
  `docs/plugins.md`.
- Authoritative convention source: `~/projects/jeeves/guides/bash-style-guide.md`.
- Stream of record for plugin work: `tasks.shellcheck-convention-plugin` (era).
- Cross-stream gate dependencies: `tasks.shellcheck` (host fork);
  `tasks.jeeves` (style-guide reconciliations).
