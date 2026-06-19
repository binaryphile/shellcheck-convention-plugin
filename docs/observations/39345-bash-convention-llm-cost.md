# Bash convention LLM cost — observation memo (#39345)

shellcheck-convention-plugin / 2026-06-19 / Claude Opus 4.7

## Correction (post-cycle, 2026-06-19) — READ BEFORE PROCEEDING

This memo's "final-byte ratio 2.18x" headline and the framing of Naming Policy headers as "agent-self-imposed boilerplate" were **both wrong**. Caught during the `/imprint` retrospective.

**The 2.18x was entirely comment overhead.** Stripping ALL comments (per-file Naming Policy header + per-function docstrings) and comparing code-only bytes:

| Spec | BSG code-only | Default code-only | Ratio |
|---|---:|---:|---:|
| 1 | 418 | 592 | 0.71 |
| 2 | 257 | 288 | 0.89 |
| 3 | 612 | 789 | 0.78 |
| 4 | 433 | 361 | 1.20 |
| 5 | 380 | 391 | 0.97 |
| **Ratio of means** | | | **0.87** |

BSG arm produces SMALLER code than Default at the code-only level — below parity.

**Both write-cost signals now point the same direction**:
- Iteration ratio: 0.80x (BSG converges in fewer cycles)
- Code-only byte ratio: 0.87x (BSG smaller)

**Why the original framing was wrong**: per existing era memory `94f1f7ac6e18` ("Every file has a Naming Policy header"), the header is convention-required prose. Per-function docstrings are in the plugin's mechanical scope. Counting comments as "cost" is the wrong frame — they're documentation, which is the convention's stated value, not its overhead.

**Unifying frame**: the BSG convention SWAPS quote-noise for comment-signal. It removes defensive quotes (the prelude makes them unnecessary) and adds docstrings + Naming Policy headers (carrying readability signal the code alone doesn't). Net byte cost on actual code is ~neutral or slightly favorable. Both the quote-removal and the comment-addition serve the same readability principle the operator stated at the session's start.

**Recommended action (corrected)**: no workflow change. The body's recommendation to "instruct agents to skip Naming Policy comments for non-API-public functions" would push agents AWAY from convention conformance. **DO NOT follow it.**

**Authoritative corrections in era**:
- `1b7ccc450169` — corrected code-only byte ratios; supersedes the body's 2.18x headline
- `c827e1ae3962` — unifying frame (convention swaps quote-noise for comment-signal)
- `56100feb6faf` — feedback memory: catch operator's narrow framings when broader correction is obvious (the surfacing path for this correction)

The cycle's METHODOLOGY findings (pre-reg cost at N=5; 3 pre-reg failure modes documented) stand unaffected.

The body below is preserved as the historical record of the cycle's original findings + framing; this correction takes precedence on the volume-cost dimension.

---

## TL;DR

Local-workflow-calibration pilot measuring the cost of producing bash under the operator's IFS+noglob + `_`-suffix discipline (BSG; enforced by shellcheck-convention-plugin SC9001-SC9010) vs default-bash behavior at N=5.

**Primary finding (methodology)**: rigorous pre-registration at N=5 is not cost-effective for measuring directional LLM-cost questions at this scale. Two `/variance` events were required at execution time and a `/scope-fold` was needed mid-cycle to salvage the original 6-criterion contract into a 4-criterion directional estimate. Pre-registration discipline likely justifies its overhead only at N=20+ where the sample size repays the up-front lock-in cost.

**Secondary finding (directional A)**:

| Metric | BSG mean | Default mean | Ratio (BSG/Default) | Operator tolerance | Verdict |
|---|---:|---:|---:|---:|---|
| Iterations to lint-clean | 1.8 | 2.4 | **0.80** | 1.5x | Within — no workflow change |
| Cumulative chars (incl. rewrites) | 1793 | 1452 | **1.75** | 1.5x | Middle band — inconclusive |
| Final-code bytes (delivered) | 1127 | 517 | **2.18** | 1.5x | Middle band — inconclusive |

BSG converges in FEWER iterations on average (counterintuitive vs. the agent's initial intuition that BSG would require more iteration) but writes more characters per delivered function. A large fraction of the volume difference is **agent-self-imposed boilerplate** (verbose docstrings, "Naming Policy" header comments) not strictly required by BSG style.

**Recommended action**: no workflow change. The convention does not cost more iterations to produce conformant bash; volume cost is partly real (BSG idioms ARE more verbose) and partly agent-discretionary (could be reduced by prompting agents to skip self-imposed docstring boilerplate).

---

## Cycle history

| Phase | Event | Notes |
|---|---|---|
| Design R1 | grade C+ / SEND BACK | 13 findings; major construct mismatch in A |
| Design R2 | grade B+ / APPROVE | 12 findings; 3 pre-reg commitments locked |
| Formalize | plan + contract #39402 + claim #39404 | impl-gate executed |
| Discovery 1 | `/variance` #39417 | pre-reg query referenced non-existent `~/projects/evtctl`; extraneous filter unsuited to A's spec-source corpus |
| Discovery 2 | corrected query → single-file dominance | strict mechanical "first 5 functions" produced 5/5 from `era-cold-vs-warm_test.bash`; effective spec diversity ≈ 1 |
| Meta R3 | grade N/A / STOP-AND-REASSESS | pre-reg ceremony approaching data's value; original estimand compromised |
| Meta R4 | grade A- / REFRAME | preserve cycle as methodology case study + leaner salvage; drop B and C |
| Scope-fold | `/scope-fold` #39474 + superseding contract #39475 | 6 criteria → 4 (B and C dropped as not decision-relevant for write-cost question) |
| Execution | 10 subagents (5 specs × 2 arms) | all converged within 5-iteration cap |

---

## Methodology case study — primary finding

### Where pre-registration breaks at N=5

The R1+R2 design was pre-registered with mechanical selection rules, scoring rubrics, and decision bands. R2 explicitly locked three pre-reg commitments to address grader findings (cross-lint rule categorization, iteration-cap handling, spec-extraction template).

At execution time, the pre-registered A corpus query failed twice:

**Failure 1 (path)**: `find ~/projects/{era,evtctl} -name '*.bash' -path '*/bin/*'`. The query referenced `~/projects/evtctl` as a sibling project. evtctl is actually a subdirectory inside era, not a separate project. The path expansion silently produced no candidates from the evtctl side.

**Failure 2 (filter)**: the query also applied `-size -2k` and "first 5 functions ≤30 LOC not already using IFS+noglob prelude." Two issues compounded: (a) era/bin/*.bash files are mostly test files in the 5-15KB range, so `-size -2k` produced zero results; (b) the "not already using IFS+noglob" filter was conceptually wrong — A's corpus provides SPECS for agents to implement, not source bash to lint. The source's style doesn't affect spec extraction. Both fixed via `/variance` #39417 (corrected query: `find ~/projects/era ~/projects/shellcheck-convention-plugin -name '*.bash' -size -10k`).

**Failure 3 (sampling)**: after correction, the strict mechanical "first 5 functions 10-30 LOC, file-position order" produced 5/5 functions from the same file (`era-cold-vs-warm_test.bash`), four of which were siblings of the same `test_sweep_*` test set. Single-file dominance reduced effective spec diversity to N≈1, undermining the pilot's inferential ambition. R3 meta-grade flagged this as methodologically fatal; R4 REFRAME called for diversification ("one function per file, alphabetical-file order") which produced 5 distinct files.

### Cost ledger

Approximate token cost by phase:

| Phase | Tokens |
|---|---:|
| Design (R1+R2, prompts + cross-vendor relay + absorption) | ~150k |
| Formalization (plan file, audit events) | ~30k |
| Meta-grades (R3+R4, prompts + relay + REFRAME absorption) | ~100k |
| Experiment A execution (10 subagents × ~100k each) | ~1,050k |
| Memo + fixtures + completion gate | ~50k (this) |
| **Cycle total** | **~1.4M tokens** |

The actual measurement (10 subagents) is ~75% of the cost; ~25% is pre-reg ceremony (design grading + formalization + meta-grades + variance handling). That ratio inverts at smaller scales: a casual "let me try this" experiment would have ~5% ceremony and ~95% measurement, producing nearly the same data at a fraction of the total cost.

### Lesson

**At N=5 with realistic execution-time discovery, pre-registration discipline costs more than the data it protects.** Pre-registration buys auditability of fork decisions, not statistical credibility. For pilot studies in this size range, an informal diversified N=5 with explicit caveats is nearly as informative at much lower overhead. The pre-reg discipline scales better at N=20+ where the larger sample justifies the up-front lock-in cost.

The three pre-reg failures themselves are valuable findings:
1. **Path-shape errors** in pre-reg queries are invisible at plan-review time; only execution catches them
2. **Filter-purpose mismatches** (the "no IFS+noglob" filter applied to a spec-source corpus where the source's style is irrelevant) are conceptual bugs that look correct in pre-reg context but fail at execution
3. **Sampling-shape failures** (single-file dominance from mechanical first-N) compromise the experiment's validity in ways the grader rounds didn't surface

Selection rules should be smoke-tested before commit. A 5-minute `find | head -5` check at pre-reg time would have caught all three failures.

---

## Experiment A — directional estimate

### Setup

5 specs drawn via diversified rule (one function per file, 10-30 LOC, alphabetical-file order across the corrected query corpus). Specs drafted by hypothesis-aware agent (informal salvage path; not operator-reviewed). Spec text describes behavior only — no naming-style hints leaked. See `39345-experiment-fixtures/specs-A.md` for verbatim spec text and `39345-experiment-fixtures/results-A-code/` for each subagent's final code.

Per spec, 2 fresh subagents in isolated `/tmp/expA-spec<N>-<arm>/`:
- **BSG arm**: prompted with bash-style-guide.md reference; iterates against `shellcheck --plugin-dir=/home/ted/projects/shellcheck-convention-plugin/result/lib/shellcheck/plugins -f gcc`
- **Default arm**: no style instruction; iterates against vanilla `shellcheck -f gcc`

Iteration cap: 5. All 10 agents converged within the cap (no cap-hit; no censored observations).

### Results

| Spec | BSG iter | Default iter | Iter ratio | BSG chars (cumulative) | Default chars | Cum-char ratio | BSG bytes (final) | Default bytes (final) | Final-byte ratio |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 installMocks | 1 | 2 | 0.50 | 1280 | 1620 | 0.79 | 1285 | 622 | 2.07 |
| 2 assert | 2 | 3 | 0.67 | 2080 | 940 | 2.21 | 1021 | 311 | 3.28 |
| 3 setupTestEnv | 1 | 3 | 0.33 | 1100 | 3050 | 0.36 | 979 | 857 | 1.14 |
| 4 test_unwrap_envelope | 1 | 2 | 0.50 | 1280 | 800 | 1.60 | 1226 | 383 | 3.20 |
| 5 setupTempRepo | 4 | 2 | 2.00 | 3226 | 850 | 3.80 | 1124 | 415 | 2.71 |
| **Mean** | **1.8** | **2.4** | **0.80** | **1793** | **1452** | **1.75** | **1127** | **517** | **2.18** |

Per-spec notes:
- **Spec 1 (installMocks)**: BSG converged on first draft; Default needed one fix cycle. BSG arm added a 600-char "Naming Policy" header comment (agent-discretionary boilerplate, not BSG-required).
- **Spec 2 (assert)**: BSG higher cumulative chars due to verbose docstring + Naming Policy + `_`-suffix discipline comment.
- **Spec 3 (setupTestEnv)**: Default arm cumulative chars high because the agent rewrote significantly across 3 iterations (cumulative penalty); final bytes much closer.
- **Spec 4 (test_unwrap)**: BSG had to add prelude + test-guard footer that Default skipped.
- **Spec 5 (setupTempRepo)**: only spec where BSG iterated more than Default (4 vs 2). BSG agent used per-command `git -C` then switched to subshell-cd pattern across iterations — convention plugin enforced quoting discipline around `$Hook` and `$tempDir_` that required several fix passes.

### Interpretation

**Iteration ratio: 0.80** — BSG arm converged in FEWER iterations on average. Counterintuitive vs. the agent's pre-experiment intuition (recorded earlier in the cycle conversation: "write cost real and recurring; priors push toward defensive quoting"). Hypothesized mechanism: the convention plugin's rules closely match what the agent ANTICIPATES while writing (because the agent reads the style guide first), so first drafts are nearly compliant. Default arm writes "natural" bash, which then triggers vanilla shellcheck's quote-defensive rules (SC2086, SC2046, SC2068, SC2206), forcing repair cycles.

**Output-volume ratios (cumulative 1.75x, final 2.18x)** — BSG arm produces more characters per delivered function. Decomposing:
- Real BSG-driven volume: prelude lines (`IFS=$'\n'; set -o noglob`), `_`-suffix discipline annotations, `local` declarations split from assignments
- Agent-discretionary volume: "Naming Policy" header comments (~600 chars in spec 1, ~700 chars in spec 2), verbose function docstrings

Looking at spec 3 where BSG arm did NOT add the Naming Policy header: final-byte ratio is 1.14 — within tolerance. Where the agent added the header, the ratio is 2-3.3x. This suggests the boilerplate is doing most of the work in the volume signal.

### Decision-rule application

Operator's pre-stated write-cost tolerance: **1.5x**. Workflow-decision bands:

| Metric | Ratio | Band | Action |
|---|---:|---|---|
| Iterations | 0.80 | < 1.5x | **Within tolerance** — no workflow change |
| Cumulative chars | 1.75 | 1.5–3x | Middle band — ambiguous at N=5 |
| Final-code bytes | 2.18 | 1.5–3x | Middle band — ambiguous at N=5 |

The iteration result is the stronger decision signal because iterations correlate more directly with LLM token cost (each iteration is a full read-lint-fix cycle with substantial context overhead). Volume metrics are weaker proxies, AND a large fraction of the measured volume is agent-discretionary boilerplate that could be cheaply suppressed by prompting agents to skip "Naming Policy" comments.

**Recommended action: no workflow change.** Optionally: a small prompt-engineering tweak ("when writing BSG-style bash, skip Naming Policy header comments unless the function is exported as part of a public API") could shrink the volume cost toward parity if the operator cares about chars per delivered function.

---

## Caveats

- **N=5 with one function per file** from one operator's corpus (era + shellcheck-convention-plugin); not statistically significant; characterized as directional only
- **Specs drafted by hypothesis-aware agent without operator review** (informal salvage per R4 REFRAME); spec-author bias not controlled
- **Subagents share parent agent's training distribution**; results apply to "agents-like-this-one in this harness" — Claude Opus 4.7 specifically. Not generalizable to other LLM families.
- **Output-char metric is approximate** — agents self-counted cumulative output; ~10-15% error band reasonable
- **Final-byte metric is exact** but excludes the cost of rewrites (only counts the delivered artifact)
- **Lint-cap of 5 not hit** by any agent; cap-handling protocol unused (no censored observations to handle)
- **Cross-lint analysis** (lint each arm's final code under other arm's rule set) was specified in R2 pre-reg as informational but **skipped in salvage execution**. Conversion-cost signal is unmeasured.
- **Asymmetric rule-set issue** (R2 finding 2) remains: BSG arm lints against stricter ruleset; iteration count being LOWER for BSG despite this is surprising and may reflect "agents anticipate stricter rules and write more carefully" rather than "BSG is intrinsically easier to satisfy."
- **Subagent thinking-token cost not captured** — character counts cover output only; internal CoT reasoning consumed tokens not counted in the OUTPUT_CHARS metric. Per-agent total token usage was 80-120k (reported by Agent tool), but breakdown of thinking vs output is opaque.
- **Order effects untested** — agents were spawned in parallel so cross-spec learning was impossible, but the order in which they happened to read style-guide sections (BSG arm) could have varied agent to agent.

---

## Resource accounting (closeout question 1)

| Item | Tokens (approx) |
|---|---:|
| Design grading rounds (R1+R2) | ~150k |
| Formalization (plan file + audit events) | ~30k |
| Meta-grading rounds (R3+R4) + REFRAME absorption | ~100k |
| Experiment A execution (10 subagents) | ~1,050k |
| Memo, fixtures, completion gate | ~50k |
| **Cycle total** | **~1.4M tokens** |

Wall-clock: ~6 hours across one session with operator-availability gates. Operator attention: ~30 min cumulative (decisions at A/B forks, /grade rounds, scope-fold approval).

For reference: the operator's original 2-paragraph intuition ("read cost small after orientation, write cost ~2x, correctness low because lint catches misses") cost ~zero tokens. The cycle's directional finding does not materially contradict it — only refines the write-cost dimension. Iteration cost is BELOW tolerance (not the "~2x" intuition suggested), volume cost is roughly AT the "~2x" intuition. R3 grader's observation that "the original intuition has not yet been materially improved by the cycle" was correct.

## Work protection (closeout question 2)

- Plan file: `~/.claude/plans/39345-bash-convention-llm-cost.md` — local
- Cycle stream events: `tasks.shellcheck-convention-plugin` — era event store (local; backed up via `era-backup-sync` discipline)
- Memo + fixtures: this commit (in repo; will be pushed to git remote)
- Grade prompts: `/tmp/grade-bash-convention-llm-cost-R[1-4]-prompt.md` — **ephemeral** (will be lost on reboot); content captured in audit events on stream
- Subagent final code: `docs/observations/39345-experiment-fixtures/results-A-code/spec[1-5]-{BSG,Default}.bash` — in repo (durable)
- Subagent transcripts: only in this conversation transcript (Claude Code JSONL)

Acceptable disposition: all decision-relevant artifacts are in git or era stream. Transcript backup depends on Claude Code's session JSONL retention. Grade prompts are not durably preserved beyond the audit event summaries (acceptable — the audit events carry the verdict + finding count; the full prompts are reconstructable from this memo + the cycle history).

## Ship distance (closeout question 3)

This cycle's deliverables ship nothing to end users. The artifacts are:
- A methodology case study durable in the repo
- A directional finding on bash convention LLM cost
- 3 audit-trail events documenting pre-reg failure modes

Distance to operator workflow change: zero — recommendation is "no workflow change." The cycle's biggest ship-relevant output is the methodology lesson, which can inform how future N=5 pilots are scoped (informal-with-caveats rather than full pre-reg ceremony). That lesson is documented here and will flow into era as a knowledge memory.

---

## Sources

- `~/.claude/plans/39345-bash-convention-llm-cost.md` — formalized plan (original 6-criterion design + GATE C + completion gate bash)
- `docs/observations/39345-experiment-fixtures/specs-A.md` — 5 spec descriptions used in Experiment A
- `docs/observations/39345-experiment-fixtures/results-A.jsonl` — per-(spec, arm) results
- `docs/observations/39345-experiment-fixtures/results-A-code/spec[1-5]-{BSG,Default}.bash` — final code per subagent
- Stream events on `tasks.shellcheck-convention-plugin`:
  - Original contract #39402 (superseded)
  - Plan event #39403
  - Claim event #39404
  - `/variance` #39417 (path + filter correction)
  - R1 grade #39381, R2 grade #39382, R3 grade #39427, R4 grade #39465
  - `/scope-fold` #39474
  - Superseding contract #39475
- `/tmp/grade-bash-convention-llm-cost-R[1-4]-prompt.md` — grade round prompts (ephemeral)

## Cycle disposition

This cycle CLOSES with the 4-criterion salvage contract fully attested. The original 6-criterion contract is superseded per contract #39475 (B and C dropped as not decision-relevant for the operator's write-cost question).

If future cycles wish to revisit the question with more statistical power:
- N=20+ per arm justifies pre-reg overhead
- Eliminate spec-extraction bias by either (a) operator extracts under blind template OR (b) use existing bash function corpora directly without re-spec
- Add a "BSG-with-no-boilerplate-budget" arm to separate convention-cost from agent-discretionary verbosity
- Run B (read accuracy) and C (orientation tax) as separate scoped cycles if their answers become decision-relevant
- Smoke-test pre-reg queries (`find | head -5`) at plan time, not at impl-gate time
