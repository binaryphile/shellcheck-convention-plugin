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
with `--enable=all` against `test/positive` and `test/negative`,
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
- **Discipline gating** (#17958): SC9003 only fires when the file
  satisfies the `fileHasIfsNoglobDiscipline` predicate from
  `Convention.hs`. Files lacking the discipline get SC9010 instead
  per the partition rule below — recommending quote-removal in a
  file without discipline would re-expose the expansion to word-
  splitting on default IFS (a regression). See §SC9010 for the
  predicate definition and the partition rule.
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
  question than SC9008's — SC9004 forbids combining `_` and `List`
  on one name; SC9008 enforces the §3 rule that `*List` is an
  IFS-serialized string (not an array).

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

### SC9008 — `*List` should be an IFS-serialized string, not an array

- **Module**: `src/ListInit.hs`
- **Severity**: `warn`
- **Always-on**: no — `cdName = "list-array-misuse"`
- **Source rule**: bash-style-guide §3 line 72 — `*List` suffix
  signals a serialized list using IFS=\n as the separator;
  must-quote on every expansion. Arrays use plural-noun suffix
  (`octopi=( inky blinky )`).
- **Pattern**: `T_Assignment` where the variable name ends in
  `List` or `List<X>` (uppercase X library marker) AND the value is
  a `T_Array` literal. Suggests a plural-noun suffix (best-effort
  pluralization strips `List` and appends `s`).
- **False-positive shape**: `declare -a xList=(...)` triggers the
  warning because `T_Assignment` doesn't see the wrapping
  `T_SimpleCommand`'s `-a` flag. Accepted as a deferred edge case;
  parent-command lookup adds disproportionate code for the gain.

#### Audit trail — prior misframe (preserved for the record)

The first SC9008 attempt (shipped 2026-05-18 in commit 5f353b7,
reverted same day in commit 90fc758) implemented the **inverse**
rule: it warned when `*List` was NOT an array. That misframe came
from umbrella task #6186 rule 5 wording ("List-suffixed variables
should be initialized as arrays"), which contradicted §3 and was
never reconciled before SC9008 shipped. tasks.jeeves #6469 closed
the contradiction with Option A (task-done #7937): §3 stands as
written. SC9008 was re-implemented with the corrected direction
under task #7951 (commit recorded on `evtctl done 7951`). The
SC9008 code itself was renewable because the rule's *direction*
was wrong, not its number-space; `cdName` changed from
`list-init-shape` (described the wrong rule) to `list-array-misuse`.

Process retrospective: era memory `ce0e0fb50087` — when
retro-claiming closure on an umbrella, read the cross-stream
follow-up tasks in full; the umbrella's original wording alone is
not sufficient context.

### SC9009 — Uninitialized-then-appended (declare without init, first materialized via +=)

- **Module**: `src/NilAvoidance.hs`
- **Severity**: `warn`
- **Always-on**: no — `cdName = "nil-avoidance"`
- **Source rule**: bash-style-guide §6 "Initialize at declaration —
  don't ship uninitialized-then-appended variables" (accelecon/jeeves
  commit b7ad13e). Operative case: within one scope, every path
  between declaration and first read uses `+=` and never a plain `=`.
- **Implementation note (lexical approximation)**: SC9009 is a
  lexical heuristic over writes ordered by source position, NOT a
  path-sensitive analysis. The check warns when every write of the
  variable lexically between its declaration and first read is in
  AppendOrRisky (T_Assignment Append or bare `read`). AlwaysInit
  writes (T_Assignment Assign, mapfile, readarray, `printf -v`,
  `(( x = ... ))`) suppress the warning. Matches §6's spec for all
  sequential and mixed-branch shapes; over-fires on conditional
  structures with an empty/write-free path (documented below).
- **Pattern**: T_SimpleCommand with cmd in {local, declare, typeset}
  and a bare-name arg AND no `-n` flag; followed in the same scope
  (T_Function body or T_Script body) by reads + writes where every
  write before the first read is AppendOrRisky.
- **Reads detected**: T_DollarBraced (covers `$x`, `${x}`, modifier
  forms via `getBracedReference`); TC_Unary with op in `{-v, -n, -z}`
  (sentinel pattern); TA_Variable inside arithmetic. Generic word
  descent via the scope walker means any context that embeds a
  T_DollarBraced (case scrutinee, for-in list, here-string, redirect
  target, command argument) is covered transitively.
- **Writes classified**:
  - AlwaysInit: T_Assignment Assign; mapfile; readarray; `printf -v`;
    T_Arithmetic with TA_Assignment (any operator).
  - AppendOrRisky: T_Assignment Append; bare `read`.
  - Invisible (false-negative shape; not detected at all): `let`,
    `eval`, `getopts`, `coproc <name>`.
- **Scope walk**: stops at nested T_Function (separate function
  scope) AND at subshell-creating nodes T_Subshell, T_DollarExpansion,
  T_ProcSub, T_Backticked, T_CoProc, T_CoProcBody. T_BraceGroup is
  NOT a scope boundary (shares parent variable scope).
- **Known false-positive shapes** (accept; mitigate via
  `# shellcheck disable=SC9009`):
  - **Conditional structures with empty / write-free path**: any
    `if`/`for`/`while`/`case` shape where at least one CFG path to
    first read skips the `+=` (empty else, zero-iteration loop,
    no-op case branch). §6 strictly is silent; lexical heuristic
    warns. Documented in `prop_sc9009_LEXICAL_OVERFIRE_silentBranch`.
  - **Sentinel pattern with non-sentinel preceding writes**: the
    sentinel form `[[ -v x ]]` / `[[ -n $x ]]` IS detected as a
    read, so `local x; [[ -v x ]] && ...` correctly does not warn.
    But `local x; x+=fallback; [[ -v x ]]` would still warn because
    the `+=` precedes the sentinel read.
- **Known false-negative shapes**:
  - **Compound-block-scoped antipattern**: §6 enumerates "function
    body, file top-level, OR compound block" as scope units. SC9009
    only dispatches on T_Function and T_Script; T_BraceGroup is
    walked through as part of the enclosing function's scope (this
    is intentional — brace groups share variable scope with their
    parent in bash). The miss: a `{ local x; x+=a; echo "$x"; }`
    nested inside a function with an UNRELATED `x=foo` elsewhere in
    that function would be silenced by the lexical heuristic (any
    AlwaysInit in scope before first read suppresses), even though
    a per-block §6 analysis would warn on the local-within-block.
    Acceptable: brace-group-scoped misses are narrow; if noisy,
    promote brace groups to dispatch in a follow-up cycle.
  - **Invisible writers**: `let "x = ..."`, `eval "x=..."`,
    `getopts opts x`, `coproc x { ... }` — write the variable but
    SC9009 doesn't recognize them as writes (string-arg forms aren't
    parsed; named-target conventions aren't modeled). If such a
    writer is the only mutation before first read, no warning fires.
    Could promote to AppendOrRisky classification in a follow-up
    cycle.
  - **Helper-function nameref mutation**: per §6, "out of scope —
    rule lives at the original declaration site, not at the
    nameref-borrowing callee". SC9009 correctly does NOT warn here.
  - **Subshell-internal antipattern**: `local x; ( local y; y+=a;
    echo "$y" )` — the inner antipattern is real in the subshell
    scope, but SC9009 doesn't dispatch on T_Subshell separately
    (only T_Function and T_Script).
  - **Sourced files**: tokens live under T_Include / T_SourceCommand,
    not in the caller's body. Scope attribution is approximate.
  - **Trap handler strings**: handler arg is a string, not parsed.
- **Notes**: first scope-aware plugin check. Intra-procedural data
  flow on per-scope token walk (lexical, not CFG-based). /grade at
  1d.5 reviewed scope-boundary edge cases and the lexical-vs-path
  divergence; lexical heuristic accepted with documented over-fire
  family.

### SC9010 — IFS+noglob discipline absent

- **Module**: `src/IfsNoglobDiscipline.hs`
- **Severity**: `style` (note)
- **Always-on**: no — `cdName = "ifs-noglob-discipline"`
- **Source rule**: bash-style-guide §3 "Enforcement" — files that
  use double-quoted variable expansions in splitting contexts should
  adopt `IFS=$'\n'` + `set -o noglob` at file top so the convention's
  quoting recommendations (per SC9001/SC9003) are sound.
- **Pattern**: a quoted non-tainted non-special variable expansion
  in a file whose discipline predicate returns False. The predicate
  uses LATEST-EFFECTIVE state on the DIRECT children of T_Script
  (non-recursive walk):
  - **IFS discipline (latest-effective)**: scan T_Script's direct
    child list in textual order; the LAST `T_Assignment` whose lvalue
    is `IFS` determines effective IFS. Discipline is present iff the
    last such assignment sets the value to EXACTLY `$'\n'` (a single
    `T_DollarSingleQuoted` whose content is literally `\n` and no
    other characters).
    - `IFS=$'\n'` → present.
    - `IFS=$'\n'; IFS=:` → absent (reassigned).
    - `IFS=$'\n\t'` → absent (multi-char; not strict newline-only).
    - `IFS="prefix"$'\n'` → absent (concatenated; not strict).
    - `IFS=` or absent → absent.
  - **noglob discipline (latest-effective)**: scan T_Script's direct
    child list for `T_SimpleCommand` invocations of `set` with `-o
    noglob` (enable) or `+o noglob` (disable). LAST invocation wins.
    - `set -o noglob` → present.
    - `set -o noglob; set +o noglob` → absent (toggle reversal).
    - `set -o noglob; set +o noglob; set -o noglob` → present (re-toggle).
    - `set -f` (short form) → NOT accepted (canonical-form-only
      minimum; if a real codebase uses `set -f`, file a follow-up
      cycle to extend acceptance).
    - No `set` invocation → absent.
  - **Both required**: file has discipline iff IFS-present AND
    noglob-present.
- **Top-level scope discipline**: only DIRECT children of T_Script
  count (non-recursive walk). Statements inside `if`/`for`/`while`/
  `case`/subshells/`{ ... }` groups/function bodies do NOT count.
  Example: `if false; then set -o noglob; fi` is conditional → does
  NOT count. `IFS=$'\n' read x` is a command-prefix inline
  assignment (parses as `T_SimpleCommand` with assignment prefix,
  not `T_Assignment`) → does NOT count.
- **Lexical/static, not runtime-complete**: the predicate inspects
  the AST of the file being linted. It does NOT follow `source` /
  `.` directives, does NOT model `eval`-generated mutations, and
  does NOT analyze runtime semantics. A file establishing discipline
  only via sourced helpers will be (correctly) reported as lacking
  discipline at the lexical level — operators wanting that case
  supported should inline the discipline at the top of the consuming
  script, OR file a future cycle for semantic source-tracking.
- **Partition with SC9003**: SC9003 and SC9010 partition the
  would-be-SC9003 trigger space cleanly via the predicate. Both
  fire PER-OCCURRENCE; the predicate determines which one fires
  at each trigger:
  - Discipline present → SC9003 fires per redundant-quote occurrence;
    SC9010 silent everywhere.
  - Discipline absent → SC9010 fires per would-be-SC9003 occurrence;
    SC9003 silent everywhere.
- **False-positive shape**: variables that legitimately could
  contain whitespace despite not having the taint suffix (same as
  SC9003's false-positive shape — the trigger pattern is shared).
- **Implementation complexity**: per-token call walks UP the parent
  map to find T_Script root, then iterates direct children. Bounded
  by top-level statement count (typically < 100). Total work O(N×K)
  where N = tokens, K = top-level statements. Acceptable for
  interactive linting; profile-driven optimization (memoization) is
  out of scope until measurement justifies.

## 4. Reference

- Host plugin system: `binaryphile/shellcheck` `docs/design.md` and
  `docs/plugins.md`.
- Authoritative convention source: `~/projects/jeeves/guides/bash-style-guide.md`.
- Stream of record for plugin work: `tasks.shellcheck-convention-plugin` (era).
- Cross-stream gate dependencies: `tasks.shellcheck` (host fork);
  `tasks.jeeves` (style-guide reconciliations).
