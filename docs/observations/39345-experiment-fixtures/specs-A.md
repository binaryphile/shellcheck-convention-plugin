# Experiment A — spec source

5 bash function specs, drawn via the post-/scope-fold (R4 REFRAME) diversified rule: one function per file, 10-30 LOC, alphabetical-file order, across `find ~/projects/era ~/projects/shellcheck-convention-plugin -name '*.bash' -size -10k`. Original function name and file location preserved here for traceability; spec text describes BEHAVIOR only (no function-name or style-mechanic hints exposed to subagents).

Per scope-fold, sample is informal, hypothesis-aware (drafted by the agent participating in the cycle), single-pass (no operator review). Caveats documented in the memo.

Each spec is presented to two subagents in isolated `/tmp/expA-spec<N>-<arm>/` working dirs:
- **BSG arm**: prompted with bash-style-guide reference; iterates against `shellcheck --plugin-dir=<plugin> -f gcc`
- **Default arm**: no style instruction; iterates against vanilla `shellcheck -f gcc`

Iteration cap: 5. Each agent reports ITERATIONS, CONVERGED, OUTPUT_CHARS, FINAL_CODE.

---

## Spec 1
**Source**: era-cold-vs-warm_test.bash:18-45 (installMocks)

Function purpose: a test-setup helper that overrides several external commands with bash function shims so the test under measurement can run hermetically and capture invocations.

The function takes one argument — the path to a log file. It should truncate this log file at start and export its path as an environment variable.

It then defines and exports the following bash function shims:
- `systemctl`, `sudo`, `sqlite3`, `curl`, `era`: each appends a single line of the form `"<command> <space-joined-args>"` to the log file and returns 0
- `waitForHealth`: overridden to immediately return 0 (no actual logic)

Side effects only — no stdout. The shims must remain callable in subprocesses after the function returns (i.e., exported into the environment).

---

## Spec 2
**Source**: era-queue-forecast_test.bash:14-23 (assert)

Function purpose: evaluate a bash condition string and record/print pass-or-fail.

Takes two positional arguments — (1) a human-readable message, (2) a bash condition string suitable for `eval`.

Behavior:
- If `eval`'ing the condition returns 0: increment a global `Pass` counter and print one line `PASS  <message>` colored green (ANSI escape sequences acceptable)
- Otherwise: increment a global `Failed` counter and print one line `FAIL  <message>` colored red

Assume `Pass` and `Failed` exist in the calling scope.

---

## Spec 3
**Source**: era-soak_test.bash:11-38 (setupTestEnv)

Function purpose: create a temporary test environment with a fresh state directory and two mock command shims on PATH so tests run hermetically.

Behavior:
- Allocate a temporary directory using a testing-framework helper named `tesht.MktempDir` that takes a variable name as argument and writes the temp-dir path into a variable of that name (it also registers cleanup automatically)
- Export an environment variable `ERA_STATE_DIR` pointing at the temp dir
- Create a subdirectory `metrics/era-serve-soak` inside the temp dir
- Create a subdirectory `mock` inside the temp dir and prepend it to PATH
- Write two executable shim scripts into the `mock` subdir:

**Shim 1: `era`** — dispatches on first arg:
- `store`: reads one line from stdin, prints `stored mock-<PID>` (PID of the shim)
- `list`: prints three lines: `a`, `b`, `c`
- `bulk-delete`: prints `deleted 0 memories`
- anything else: prints `mock-era: unknown <args>` to stderr and exits 1

**Shim 2: `systemctl`** — ignores a leading `--user` argument if present, then dispatches:
- `show`: prints `MainPID=0`
- anything else: exits 0 silently

The function does not need its own cleanup — relies on `tesht.MktempDir`'s registration.

---

## Spec 4
**Source**: era_unwrap_test.bash:17-27 (test_unwrap_envelopeSuccess_objectData)

Function purpose: assert that a function named `era.Unwrap` correctly extracts the `data` field from a success-envelope JSON object.

The function takes no arguments.

Behavior:
- Pipe the literal JSON `{"ok":true,"data":{"foo":1}}` through `era.Unwrap`, then through `jq -c .` (compact JSON output)
- If the pipeline exits non-zero, log a diagnostic message `envelope success returned nonzero exit` using a testing-framework helper named `tesht.Log` (takes one string argument; prints to test output), and return 1
- If the result is not exactly the string `{"foo":1}`, call `tesht.Log "envelope success body mismatch: got: <actual>"` and return 1
- Otherwise return 0

Assume `era.Unwrap` is a function in scope and `jq` is on PATH.

---

## Spec 5
**Source**: githooks_pre_commit_test.bash:29-51 (setupTempRepo)

Function purpose: create a temporary git repository configured for hermetic hook testing, with a specified hook symlinked into the repo's hooks dir.

Reads a global variable `Hook` containing the absolute path to the hook file to symlink. Takes no positional arguments.

Behavior:
- Create a temporary directory (e.g., via `mktemp -d`)
- Inside that directory, run `git init` quietly (suppress its initial-branch-name advice if possible)
- Configure `user.email=t@t` and `user.name=t`
- Override `core.hooksPath=.git/hooks` (defeats any inherited global `hooksPath` setting that would bypass the symlinked hook)
- Disable `commit.gpgsign` (avoids prompting any inherited external signing tool such as a 1Password-integrated SSH signer when the session is locked)
- Symlink `$Hook` to `.git/hooks/pre-commit`
- Print the absolute path of the temp dir to stdout (no trailing newline)

Do not clean up the temp dir — caller is responsible.
