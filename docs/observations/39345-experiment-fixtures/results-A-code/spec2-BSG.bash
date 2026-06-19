#!/usr/bin/env bash

# Naming Policy:
#
# Standalone script — no namespace prefix on functions, no suffix on globals.
# Local variable names begin with lowercase, e.g. localVariable.
# Global variable names begin with uppercase, e.g. GlobalVariable.
# Variables ending in _ may contain IFS characters or be empty; must be
# quoted on use.

IFS=$'\n'
set -o noglob

Green=$'\033[32m'
Red=$'\033[31m'
Reset=$'\033[0m'

# assert evaluates `cond_` and prints a PASS/FAIL line for `msg`.
#
# On rc=0, increments the caller's `Pass` counter and prints
# `PASS  <msg>` in green. Otherwise increments the caller's `Failed`
# counter and prints `FAIL  <msg>` in red. Reads and mutates the
# caller's `Pass` / `Failed` globals via dynamic scoping. cond_ is
# _-suffixed because it may contain arbitrary shell metacharacters
# and IFS characters.
assert() {
  local msg=$1 cond_=$2

  if eval "$cond_"; then
    (( Pass += 1 ))
    echo $Green'PASS  '$msg$Reset
  else
    (( Failed += 1 ))
    echo $Red'FAIL  '$msg$Reset
  fi
}
