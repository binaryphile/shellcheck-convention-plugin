#!/usr/bin/env bash

# $BASH_SOURCE refers to the tesht binary inside an eval'd test body, not
# this file -- use tesht's exported TESHT_TEST_FILE instead (see
# tesht.testFile's doc comment / docs/tesht.md "Script discovery").
Hook="$(dirname "$TESHT_TEST_FILE")/commit-msg"

setupRepo_() {
  local -n outDir_=$1
  tesht.MktempDir outDir_ || return 128
  cd "$outDir_" || return 128
  git init -q -b main .
  git config user.email test@example.com
  git config user.name Test
}

test_rejects_wip_subjects_on_main() {
  local -A case1=([name]='wip prefix'         [subject]='wip: something')
  local -A case2=([name]='fixme prefix'       [subject]='fixme later')
  local -A case3=([name]='tmp prefix'         [subject]='tmp checkpoint')
  local -A case4=([name]='squash prefix'      [subject]='squash me')
  local -A case5=([name]='hack prefix'        [subject]='hack around bug')
  local -A case6=([name]='xxx prefix'         [subject]='XXX finish this')
  local -A case7=([name]='todo prefix'        [subject]='TODO add tests')
  local -A case8=([name]='do not push phrase' [subject]='experiment, do not push')
  local -A case9=([name]='do not merge phrase' [subject]='draft - do not merge')

  subtest() {
    local casename=$1
    eval "$(tesht.Inherit "$casename")"

    local dir_
    setupRepo_ dir_ || return 128

    local msgFile_=msg.txt
    printf '%s\n' "$subject" >"$msgFile_"

    local rc
    "$Hook" "$msgFile_" && rc=$? || rc=$?
    tesht.AssertRC "$rc" 1
  }

  tesht.Run ${!case@}
}

test_allows_wip_subject_on_non_main_branch() {
  local dir_
  setupRepo_ dir_ || return 128

  git checkout -q -b orch-test-branch

  local msgFile_=msg.txt
  printf 'wip: something\n' >"$msgFile_"

  local rc
  "$Hook" "$msgFile_" && rc=$? || rc=$?
  tesht.AssertRC "$rc" 0
}

test_allows_normal_subject_on_main() {
  local dir_
  setupRepo_ dir_ || return 128

  local msgFile_=msg.txt
  printf 'Add sibling-test pre-commit gate\n' >"$msgFile_"

  local rc
  "$Hook" "$msgFile_" && rc=$? || rc=$?
  tesht.AssertRC "$rc" 0
}

test_wipOverride_bypasses_check_on_main() {
  local dir_
  setupRepo_ dir_ || return 128

  local msgFile_=msg.txt
  printf 'wip: something\n' >"$msgFile_"

  local rc got
  got=$(WIP_OVERRIDE='reason: intentional wip commit' "$Hook" "$msgFile_" 2>&1) && rc=$? || rc=$?
  tesht.AssertRC "$rc" 0
  [[ $got == *WIP_OVERRIDE* ]] || { echo "expected warning mentioning WIP_OVERRIDE, got: $got"; return 1; }
}
