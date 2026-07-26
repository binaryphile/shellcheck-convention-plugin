# Fragment mode (#37003)

The convention plugin can suppress its two scope-aware checks
(SC9001, SC9002) when the lint target is a *fragment* — a snippet
whose enclosing function body or script preamble lies outside the
input. Enabled by an env var on the shellcheck process:

```
SC_PLUGIN_FRAGMENT=1 shellcheck --plugin-dir DIR -f gcc snippet.bash
```

## Motivation

Both SC9001 (unquoted `$NAME_` in a splitting context) and SC9002
(cmdsub assigned to a non-`_`-suffixed variable) carry an exception
from #36870 for `-i`-typed variables: bash coerces every assignment
to an integer-typed variable, so the IFS-splitting and
captured-newline hazards the convention guards against cannot apply.

The exception is *scope-aware*: it looks up the nearest enclosing
`T_Function` or `T_Script` body for the matching `local -i NAME` /
`declare -i NAME` / `typeset -i NAME` / `readonly -i NAME`
declaration. When the input is a fragment that doesn't include that
declaration, the scope check fails and the nudges fire even though
the full file would silence them. Common trigger: a code-editor tool
linting just the snippet a user is about to insert into a function.

Fragment mode suppresses SC9001 and SC9002 unconditionally when no
visible `-i` decl is present, on the basis that the consumer has
explicitly signalled the visible scope is incomplete.

## What it does not affect

* **SC9003-SC9011**: none depends on an `-i` declaration lookup
  *outside* the visible snippet, so `SC_PLUGIN_FRAGMENT` has no effect
  on any of them — they don't need the off-switch SC9001/SC9002 do.
  SC9003-SC9010 evaluate local AST shape (quoting, identifier shape,
  numeric form, IFS+noglob discipline) and are genuinely self-contained
  on any fragment. **SC9011 is a partial exception** (IMPL /grade
  finding, task #80805): it makes a scope-wide universal claim (every
  write after declaration, every bare-name occurrence, every
  `eval`/`source`/`.` anywhere in the enclosing scope must be safe/
  absent). A fragment that's truncated *before* a later disqualifying
  write, escape occurrence, or `eval`/`source` call that lives further
  down in the same complete function can cause SC9011 to warn on the
  fragment even though the full file would correctly stay silent —
  the opposite failure direction from SC9001/SC9002's issue (which
  produces false positives from a MISSING declaration, not a missing
  disqualifying write). Fragment mode does not currently address this;
  it isn't in scope for `SC_PLUGIN_FRAGMENT`'s existing `-i`-lookup
  mechanism.
* **Base shellcheck SC1xxx parse errors**: emitted by the shellcheck
  parser before any plugin check runs. The plugin .so cannot suppress
  these. Consumers that lint fragments which may be incomplete (mid-
  function, mid-heredoc, etc.) should keep their own SC1xxx filter on
  the output side. With `-f gcc`, one line per error:

  ```
  shellcheck ... | grep -v -E '\[SC1[0-9]{3}\]'
  ```

## Recommended consumer pattern

```bash
SC_PLUGIN_FRAGMENT=1 shellcheck --plugin-dir "$plugin_dir_" -f gcc "$tmp_" 2>&1 |
  grep -v -E '\[SC1[0-9]{3}\]'
```

`~/dotfiles/claude/claude-bash-lint-guard` (the Edit-tool consumer
this mode was added for) already filters SC1xxx for fragments. With
`SC_PLUGIN_FRAGMENT=1` exported on the shellcheck invocation, the
guard can stop seeing SC9001/SC9002 false-positives from the
#36870 scope check.

## Tests

`test/fragment-positive` exercises the toggle. `bin/verify` asserts:

1. Without `SC_PLUGIN_FRAGMENT`, SC9001 + SC9002 fire (proves the
   fixture actually exercises the path).
2. With `SC_PLUGIN_FRAGMENT=1`, both suppress on the same fixture.
3. With `SC_PLUGIN_FRAGMENT=1`, SC9003-SC9009 and SC9011 still fire on
   `test/positive` (no bleed into the non-scope-aware checks).
