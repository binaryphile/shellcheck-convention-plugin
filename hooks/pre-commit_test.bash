#!/usr/bin/env bash

# $BASH_SOURCE refers to the tesht binary inside an eval'd test body, not
# this file -- use tesht's exported TESHT_TEST_FILE instead (see
# tesht.testFile's doc comment / docs/tesht.md "Script discovery").
Hook="$(dirname "$TESHT_TEST_FILE")/pre-commit"

# Sibling test fixtures below are generated through an unquoted heredoc
# with the function name substituted from a variable ($testFn_), rather
# than written as a literal "test_foo() {" line. tesht.listTestnames
# statically greps every *_test.bash FILE for lines starting with
# "test_" -- a literal match inside this file's own heredoc text would
# register as a phantom test here even though it only ever runs inside
# the generated script_test.bash.

setupRepo_() {
  local -n outDir_=$1
  tesht.MktempDir outDir_ || return 128
  cd "$outDir_" || return 128
  git init -q -b main .
  git config user.email test@example.com
  git config user.name Test
}

test_runs_passing_sibling_test() {
  local dir_
  setupRepo_ dir_ || return 128

  cat >script.bash <<'END'
#!/usr/bin/env bash
greet() { echo "hello $1"; }
END

  local testFn_=test_greet
  cat >script_test.bash <<END
${testFn_}() {
  local got
  got=\$(source ./script.bash; greet world)
  [[ \$got == 'hello world' ]] || { echo "got: \$got"; return 1; }
}
END

  git add script.bash script_test.bash

  local rc
  "$Hook" && rc=$? || rc=$?
  tesht.AssertRC "$rc" 0
}

test_rejects_failing_sibling_test() {
  local dir_
  setupRepo_ dir_ || return 128

  cat >script.bash <<'END'
#!/usr/bin/env bash
greet() { echo "hello $1"; }
END

  local testFn_=test_greet
  cat >script_test.bash <<END
${testFn_}() {
  echo "forced failure"
  return 1
}
END

  git add script.bash script_test.bash

  local rc
  "$Hook" && rc=$? || rc=$?
  tesht.AssertRC "$rc" 1
}

test_allows_bash_script_with_no_sibling_test() {
  local dir_
  setupRepo_ dir_ || return 128

  cat >script.bash <<'END'
#!/usr/bin/env bash
echo hi
END

  git add script.bash

  local rc
  "$Hook" && rc=$? || rc=$?
  tesht.AssertRC "$rc" 0
}

test_skip_teshtCheck_override_bypasses_failing_test() {
  local dir_
  setupRepo_ dir_ || return 128

  cat >script.bash <<'END'
#!/usr/bin/env bash
greet() { echo "hello $1"; }
END

  local testFn_=test_greet
  cat >script_test.bash <<END
${testFn_}() {
  return 1
}
END

  git add script.bash script_test.bash

  local rc got
  got=$(SKIP_TESHT_CHECK='reason: testing bypass' "$Hook" 2>&1) && rc=$? || rc=$?
  tesht.AssertRC "$rc" 0
  [[ $got == *SKIP_TESHT_CHECK* ]] || { echo "expected warning mentioning SKIP_TESHT_CHECK, got: $got"; return 1; }
}
