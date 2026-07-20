# UserSov Phase-3 Review of shellcheck-convention-plugin

Phase-3 tooling-sweep review of shellcheck-convention-plugin against `usersov-framework-guide.md`,
per icarus #70311 (task #79363). 10th review in the sweep, following era, cascadia,
tandem-protocol, dotfiles, dojo, jeeves, evtctl, mk.bash, and tesht. Follows the guide's 8-block
grading-payload contract (§10).

**Process note**: no cross-vendor `/grade` round obtainable — autonomous mode is active and
wl-copy paste-back is forbidden under autonomous mode (operator-refined rule, era memory
`10d230c441f1`/`ad7b7826dd88`). Self-review applied the same rubric and construction-check
discipline the cross-vendor rounds used elsewhere in this sweep; the Analysis grade below is
capped one notch, per the guide's own discipline that unverified self-assessment is a capped
condition. Logged as `/variance` (event #79365).

**Scope-and-result framing note, stated up front**: this review found **zero threat records**.
The tool is a pure static-analysis ShellCheck plugin with no runtime data flows of any kind. Per
the guide's own discipline ("a rigorous analysis may correctly report an N/A-heavy posture — that
is a successful review") and this sweep's own prior finding that forcing a record to match
sibling reviews' shape is itself a risk worth naming (surfaced during this sweep's cascadia rename
grading rounds), this review does not manufacture a finding. Every property below carries a
reasoned N/A with real, stated evidence — not a silent blank.

## Block 1 — Trigger, scope, profile, priorities

**Trigger**: Phase-3 tooling sweep (icarus #70311); shellcheck-convention-plugin is the 10th of
~14 tools.

**Scope**: the plugin's own implementation (`src/*.hs`, ~1500 lines across 10 check modules,
`bin/verify`, `bin/claude`), its build/load mechanism, and its test fixtures.

**Profile**: Class H (standard professional/developer — the estate's operator).

**Class H modulations**: none materially apply — there is no data flow for workplace-exposure or
long-horizon-aggregation priorities to modulate. The tool's entire purpose is local, ephemeral
static analysis of the operator's own bash source files.

## Block 2 — Data classes + subjects

| Data class | Subject + role |
|---|---|
| Bash script source text passed to the plugin for analysis (via ShellCheck's own invocation) | Operator — sole subject |
| Lint diagnostics emitted (file:line + message) | Operator — sole subject |

No third-party-data subject role applies — the plugin analyzes whatever bash source ShellCheck
feeds it, which in this estate's actual usage is always the operator's own scripts.

## Block 3 — Data-flow inventory

**Sources**: bash script source text, handed to the plugin's check functions by ShellCheck's own
AST-walking machinery at analysis time.

**Processes**: `libconvention-checks.so`, a compiled Haskell shared library, `dlopen`-loaded by a
ShellCheck fork at startup (per `docs/design.md` §1: "The plugin is a single
`libconvention-checks.so` shared library loaded by `binaryphile/shellcheck` via `dlopen` at
startup"). Each of the 10 check modules (`TaintSuffix`, `MutualExclusive`, `TaintAssignment`,
`UnnecessaryQuoting`, `Numerics`, `Inclusive`, `Docstring`, `ListInit`, `NilAvoidance`,
`IfsNoglobDiscipline`) is a pure function over the AST — verified via `src/Plugin.hs`'s full
registry (`plugin_init`, 10 lines, one per check).

**Stores**: none — the plugin holds no state across invocations; it's a stateless analysis pass
per ShellCheck run.

**Flows**: none beyond the local ShellCheck invocation's own stdout/stderr (diagnostics printed
in whatever format ShellCheck itself was invoked with, e.g. `-f gcc`).

**Exits**: none. No network call, no telemetry, no file write beyond what the compiled `.so`
artifact itself is (a build output, not a runtime data exit).

**Deletion paths**: N/A — nothing persists to delete.

**Trust boundaries**: none beyond the operator's own machine — the plugin never leaves the local
build/lint invocation.

**Derived surfaces**: none identified with a feasible threat. `bin/verify` (the build/test driver)
and `bin/claude` (the generic Nix-wrapper pattern already reviewed elsewhere in this sweep, not
project-specific) were both inspected — both are local-only build/test tooling with no network or
credential surface.

## Block 4 — Per-property disposition

No threat records this review — see the disposition matrix below for the reasoned N/A per
property.

## Disposition matrix

Surface (rows) × property (columns, 1–11). Every cell is `N/A` with reasoning below — no
`RECORD-ID`s this review.

| Surface | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Plugin analysis pass (10 check modules) | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A |
| `bin/verify` build/test driver | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A |

**Reasoned N/A, grouped**:

- **Properties 1 (Linkability), 2 (Identifiability), 4 (Detectability)**: N/A — the plugin holds
  no state across invocations and correlates nothing; there is no cross-context or cross-session
  data for these properties to apply to.
- **Property 3 (Non-repudiation)**: N/A, same estate-wide reasoning every prior sweep review
  established — attribution is the declared posture for Class H work artifacts, not deniability
  (though this property barely applies here at all, since the plugin produces no attributable
  claims about the operator — only diagnostics about their bash source).
- **Property 5 (Data disclosure)**: N/A — verified code-confirmed (full source read of all 10
  check modules plus `Plugin.hs`'s registry) that nothing leaves the local ShellCheck invocation.
  No network call anywhere in the plugin's own source.
- **Property 6 (Unawareness & unintervenability)**: N/A — the plugin only runs when ShellCheck is
  explicitly invoked with the plugin loaded; there is no ambient/background capture to be unaware
  of or unable to stop.
- **Property 7 (Non-compliance)**: N/A — the plugin makes no external policy claims for a
  compliance-drift check to apply to.
- **Property 8 (Expungability failure) and 11 (Compulsion-resistance failure)**: N/A — no
  persistent store of any kind, nothing to delete and nothing for a compulsion order to reach.
- **Property 9 (Delegation integrity loss)**: N/A — the plugin has no delegation boundary; it is
  a pure function invoked synchronously by ShellCheck, never dispatched or run on the operator's
  behalf by another actor.
- **Property 10 (Substrate transparency/control failure)**: N/A — the plugin only activates when
  explicitly loaded via `--plugin-dir`; confirmed via `bin/verify`'s own test harness, which
  asserts the exact string `Loaded plugin: libconvention-checks.so (10 check(s))` appears in
  ShellCheck's own log output before treating a test run as valid. No silent, undisclosed capture
  mechanism exists.

## Block 5 — Controls + evidence

- Control: no network call, telemetry, or credential-file access anywhere in the plugin's ~1500
  lines of Haskell source. Evidence status: code-confirmed (full source read of all 10 check
  modules plus the plugin registry).
- Control: the plugin only activates when explicitly `dlopen`-loaded via `--plugin-dir` — not a
  default ShellCheck behavior. Evidence status: code-confirmed (`bin/verify`'s own assertion that
  the dlopen-success log line appears).
- Control: no CI/workflow automation exists for this repo (`.github/` absent) — confirmed via
  direct filesystem check. Nothing runs this plugin against operator data on a schedule or
  automatically.
- Control: test fixtures (`test/positive`, `test/adversarial`, `test/negative`, etc.) contain no
  credential-shaped content. Evidence status: code-confirmed (grepped for
  TOKEN/SECRET/PASSWORD/api_key/credential across the full `test/` tree, zero hits).

No internal contradictions were found among these controls.

## Block 6 — Assumptions, deferrals, accepted risks

Assumed: none load-bearing — the tool's own surface is fully accounted for without relying on
unverified assumptions about downstream consumer behavior (unlike several sibling reviews in this
sweep, this tool has no meaningful consumer-side variance to assume about, since it produces only
local stdout diagnostics).

Deferred: none.

Accepted risks: none — no live threat record exists to accept residual risk against.

## Block 7 — Grade triplet (self-assessment)

```
Grade: A-           (payload complete across all 8 blocks; genuinely thin/clean tool with zero
                     threat records, each of the 11 properties individually reasoned with real
                     evidence rather than a silent blank; did not manufacture a finding to match
                     sibling reviews' shape. CAPPED ONE NOTCH below what this analysis would
                     otherwise earn for lacking a cross-vendor adversarial round -- autonomous
                     mode, wl-copy forbidden, same constraint tesht's review logged earlier this
                     sweep.)
Posture: A           (nothing to find -- pure static-analysis plugin, no network, no telemetry,
                     no credential handling, no persistent state, no CI automation. The cleanest
                     posture in this sweep so far.)
Remediation: NOT APPLICABLE   (no findings to remediate)
```

## Block 8 — Remediation capabilities + verification

None — no findings this review.
