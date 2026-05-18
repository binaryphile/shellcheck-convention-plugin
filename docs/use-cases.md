# Use Cases: shellcheck-convention-plugin

Cockburn-shape use cases for the IFS/noglob convention check plugin
(SC9001-SC9007). The plugin loads dynamically into the upstream
shellcheck fork (`binaryphile/shellcheck`); the use cases below
describe WHAT the plugin does from three stakeholder perspectives.
Mechanism (HOW) lives in [design.md](design.md).

## Stakeholders

| Stakeholder | Interest |
|---|---|
| **Plugin Maintainer** (PM) | Add, revise, or revert convention checks without breaking the build or the test surface. Wants per-check `prop_` coverage, an end-to-end `bin/verify` gate, and a clear audit trail when rules change. |
| **End-user** (EU) | Get bash-style-guide convention warnings while running `shellcheck` as usual. Wants opt-in, predictable interleaving with built-in warnings, and `# shellcheck disable=` suppression. |
| **Style Guide Author** (SGA) | Codify a rule once in `bash-style-guide.md` (canonical source) and have the plugin enforce it consistently. Wants explicit citations from check rationale back to the rule. |

---

## UC-1: Add a new convention check

| Field | Value |
|---|---|
| **Scope** | The plugin source tree, the nix flake, the registration registry, the test fixtures, and the end-to-end verify script. |
| **Level** | User-goal (a complete add-and-ship workflow within one cycle). |
| **Primary Actor** | Plugin Maintainer. |
| **Other Stakeholders** | End-user (cares the new check is loadable + opt-in works); Style Guide Author (cares the check matches the rule's intent). |

### Preconditions

- A clean working tree on `main`.
- Host pin (`flake.lock`) is current enough to expose any new
  `Base.hs` API the check uses (e.g., `getDocCommentsBefore` requires
  `pluginApiVersion = 2`, ddbd0c3+).
- The convention exists somewhere authoritative — typically a section
  in `bash-style-guide.md`.

### Minimal Guarantee

If the check module compiles, it ships behind its `cdName` opt-in
(or always-on if so declared). A check that breaks an existing
fixture is caught by `bin/verify` before commit; a check that doesn't
fire on its intended positive fixture is caught by the same gate.

### Success Guarantee (Postconditions)

- New `src/<CheckName>.hs` exists with a `check :: CustomCheck`
  export and inline `prop_<sc>_*` tests.
- `src/Plugin.hs` lists the check in `plugin_init` and the
  module-comment enumeration.
- `flake.nix`'s `buildPhase` lists `src/<CheckName>.hs` (otherwise
  `ghc` won't compile it into the `.so`).
- `bin/verify`'s `codes` array includes the new SC code, the
  "Loaded plugin" assertion's check count is bumped, and the final
  OK message reflects the new range.
- `test/positive` has at least one fixture that fires the new
  check; `test/negative` has at least one fixture that stays
  silent.
- `nix build .#default` green; `bin/verify` exits 0 with the
  expected OK line.

### Trigger

Plugin Maintainer (or downstream consumer) identifies a convention
violation pattern that recurs across scripts and decides to enforce
it.

### Main Success Scenario

1. PM creates `src/<CheckName>.hs` with module header, imports
   (`ShellCheck.AST`, `ASTLib`, `AnalyzerLib`,
   `Checks.Custom.Base`, `Convention` if reusing helpers), a `check
   :: CustomCheck` value, the `Token -> Analysis` function, and
   inline `prop_sc<N>_*` tests using `verify` / `verifyNot` /
   `verifyCode`.
2. PM `git add`s the new file (untracked files don't reach nix flake
   builds — see Extension 2a).
3. PM appends the check to `src/Plugin.hs` `plugin_init` list and
   adds a row to the module-comment enumeration.
4. PM adds `src/<CheckName>.hs` to `flake.nix`'s `buildPhase` ghc
   invocation.
5. PM adds the new SC code to `bin/verify`'s `codes` array, bumps
   the "Loaded plugin: ... (N check(s))" regex, and updates the
   final OK message.
6. PM adds a positive fixture to `test/positive` and a negative
   fixture to `test/negative`.
7. PM runs `nix build .#default` — should succeed.
8. PM runs `bin/verify` — should exit 0 with "OK: SC9001-SC<new>
   emitted on positive, silent on negative; dlopen confirmed".
9. PM commits, pushes, attestation, done event closes the cycle.

### Extensions

- **2a.** PM forgot `git add` → nix build fails with
  `Can't find src/<CheckName>.hs`. Fix: `git add` the new file
  (commit not required).
- **3a.** Check is always-on rather than optional → `ccAlwaysOn =
  True` and no `--enable=` needed; PM may skip the `cdName` opt-in
  but `cdDescription` is still required.
- **5a.** End-to-end fixture for the new check accidentally fires
  another SCxxxx code (e.g., section-header comment in fixture
  becomes a false-positive docstring) → restructure the fixture
  (blank-line separation, neutral header text). This bit the SC9007
  cycle on 2026-05-17.
- **7a.** `nix build` fails with "missing module ShellCheck.X" →
  flake host pin is stale; `nix flake update shellcheck` and
  rebuild.
- **8a.** Check fires on positive fixture but ALSO on negative
  fixture → either the check is over-broad (revise predicate) or
  the negative fixture happens to match the rule unintentionally
  (revise fixture).
- **8b.** Plugin loads (`Loaded plugin: ... (N check(s))`) but check
  doesn't fire on positive fixture → host pin too old to expose the
  Base.hs API the check uses; bump flake.lock. This bit the SC9007
  smoke-test on 2026-05-17.

---

## UC-2: Enable convention checks while running shellcheck

| Field | Value |
|---|---|
| **Scope** | An end-user's shellcheck invocation that loads this plugin. |
| **Level** | User-goal (one shellcheck run producing plugin-sourced warnings). |
| **Primary Actor** | End-user running shellcheck on their script(s). |
| **Other Stakeholders** | Plugin Maintainer (cares the `.so` loads cleanly); Style Guide Author (cares the rules they codified are enforced). |

### Preconditions

- A built `libconvention-checks.so` accessible to the user (typically
  via `nix build` or a binary install).
- Shellcheck binary built from `binaryphile/shellcheck` with
  `-rdynamic`.
- The user knows which optional checks they want (from
  `shellcheck --list-optional` or this plugin's `docs/design.md` §3
  catalog).

### Minimal Guarantee

If the plugin fails to load (ABI mismatch, missing symbol),
shellcheck logs to stderr and continues with built-in checks. A
broken plugin does not crash shellcheck or silently disable
unrelated checks.

### Success Guarantee (Postconditions)

- Stderr shows `Loaded plugin: libconvention-checks.so (N check(s))`.
- For each enabled SC code, the script's violations emit warnings
  with the configured severity and message.
- Built-in SC1xxx-SC3xxx warnings emit alongside the plugin
  warnings, ordered by source position.
- `# shellcheck disable=SC9xxx` directives in the script suppress
  the matching plugin warning identically to a built-in warning.

### Trigger

The user wants to enforce IFS/noglob, inclusive language, docstring
shape, or other plugin-provided conventions on their scripts.

### Main Success Scenario

1. EU installs `libconvention-checks.so` to
   `$XDG_DATA_HOME/shellcheck/plugins/` (or passes
   `--plugin-dir <path>` per shellcheck invocation).
2. EU adds `enable=docstring-shape,inclusive-language,...` to
   `~/.shellcheckrc` (or passes `--enable=` per invocation; or
   `--enable=all` for every optional check).
3. EU runs `shellcheck <script.sh>` (or per the chosen formatter,
   e.g. `-f gcc`).
4. Shellcheck logs the plugin-loaded line to stderr.
5. For each script, plugin checks run on every AST token; warnings
   emit interleaved with built-in checks in source order.
6. EU addresses violations or adds `# shellcheck disable=SC9xxx`
   suppressions where appropriate.

### Extensions

- **1a.** `$XDG_DATA_HOME` unset → shellcheck falls back to
  `~/.local/share/shellcheck/plugins/`.
- **2a.** EU uses `--enable=all` → every `ccAlwaysOn = False`
  plugin check fires; useful for first-time scan, noisy afterward.
- **2b.** EU enables a check whose `cdName` doesn't match (typo) →
  shellcheck silently skips it; verify the name via
  `--list-optional`.
- **4a.** Plugin's `pluginApiVersion` doesn't match host's → load
  fails with version-mismatch message; rebuild plugin against the
  matching host commit.
- **5a.** Two plugins (unrelated, both loaded) emit on the same
  token → both fire; deduplication only happens on identical
  `(severity, code, position, message)` tuples.

---

## UC-3: Revise or revert a check when the source rule changes

| Field | Value |
|---|---|
| **Scope** | An already-shipped check whose implemented behavior no longer matches its source rule (typically due to a misframing in the original task, a style-guide revision, or a false-positive cluster). |
| **Level** | User-goal (one revise-or-revert cycle that leaves the audit trail honest). |
| **Primary Actor** | Plugin Maintainer. |
| **Other Stakeholders** | Style Guide Author (whose authoritative ruling drives the revision); End-user (whose noisy or wrong warnings stop emitting). |

### Preconditions

- A check is live in `main` (registered, loadable, firing on
  scripts).
- A reconciliation question on the corresponding doc-side task
  (typically tasks.jeeves) has resolved differently than the check's
  implementation assumes — OR a false-positive cluster has been
  reported.

### Minimal Guarantee

The revert leaves the plugin in a buildable, end-to-end-verifiable
state. The audit trail (commits, era events, retro memories) clearly
records that the rule shipped, what was wrong, and what supersedes
it.

### Success Guarantee (Postconditions)

- The wrong check is removed from `main` either by `git revert <bad
  SHA>` (preferred — keeps the bad code in history but unshipped) or
  by an in-place rewrite that explicitly references the old commit.
- `bin/verify` end-to-end green at the new HEAD.
- A new task on this stream (`tasks.shellcheck-convention-plugin`)
  is filed for the corrected implementation, referencing the revert
  commit, the reconciliation task on the upstream doc stream, and
  the prior `era` retro memory.
- Stream-visible correction interaction events are published on every
  stream where the original retro lived (this plugin's stream, the
  upstream stream that filed the umbrella, the doc stream that
  resolved the rule).
- A new `era store --type knowledge` memory supersedes the prior
  retro on the affected row(s).

### Trigger

A doc-side reconciliation closes against the check's implementation
direction, OR a false-positive cluster shows the check is enforcing
the wrong shape.

### Main Success Scenario

1. PM verifies the rule reconciliation outcome (read the closed
   doc-side task in full; do not infer from the umbrella's original
   wording — that was the SC9008 lesson).
2. PM runs `git revert --no-edit <bad SHA>` on `main`.
3. PM runs `nix build .#default` and `bin/verify` to confirm the
   reverted plugin builds and verifies clean (back to N-1 checks).
4. PM pushes the revert.
5. PM closes the doc-side reconciliation task with a `task-done`
   event recording which option won and citing the revert SHA.
6. PM files a new task on this stream for the corrected check; task
   body cites the revert SHA, the doc-side resolution event, and the
   prior retro memory hash.
7. PM publishes correction interaction events on every stream that
   carries the now-wrong retro.
8. PM stores a new `era` knowledge memory superseding the prior
   retro on the affected row(s).

### Extensions

- **2a.** PM prefers in-place rewrite over `git revert` (e.g., the
  check is large and the rewrite is small) → write the corrected
  version in a new commit; reference the old commit in the message.
  `git revert` is recommended for trivial-tier reverts to keep the
  audit obvious.
- **6a.** PM wants to reuse the SC code → renumber only if the rule
  changed substantively; reuse if the implementation was buggy but
  the rule's intent is unchanged. SC9008's first attempt reused the
  code because the rule's number-space wasn't the problem (the
  rule's *direction* was).
- **8a.** PM forgets to amend the retro memory → future-session
  recall via `era search` returns the stale claim; either redo
  step 8 (preferred) or live with future-session ambiguity until
  someone notices.

---

## Cross-UC invariants

- **`bin/verify` is the contract gate.** Every UC's success
  postcondition includes `bin/verify` exit 0. CI doesn't exist yet;
  this script is the manual stand-in.
- **`era` events are the audit trail.** Every check ship, revert,
  or revision should leave at least one stream event (contract +
  complete + done at minimum; interactions for corrections). Era
  knowledge memories layer on top for cross-session recall.
- **The host pin is load-bearing.** Plugin checks that use new
  `Base.hs` APIs will silently no-op if the host pin is stale (e.g.,
  `getDocCommentsBefore` returns `[]` against pre-#7469 hosts).
  Bump the pin alongside any check that consumes new host API.
