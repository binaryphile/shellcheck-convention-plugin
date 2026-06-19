#!/usr/bin/env bash

# Naming Policy:
#
# This is a standalone script — no namespace prefix on functions, no suffix on globals.
# Function names use camelCase (test_* per tesht convention).
# Local variable names begin with lowercase, e.g. localVariable.
# Global variable names begin with uppercase, e.g. GlobalVariable.
# Variables ending in _ may contain IFS characters or be empty; must be
# quoted on use. *List / *Lists suffix is the multi-value alternative.

# test_unwrap_envelopeSuccess_objectData asserts that era.Unwrap extracts the
# `data` field from a success-envelope JSON object.
#
# Pipes a literal success envelope through era.Unwrap and `jq -c .`, then
# compares against the expected compact JSON. Logs via tesht.Log and returns 1
# on mismatch or pipeline failure.
test_unwrap_envelopeSuccess_objectData() {
  local got_ want='{"foo":1}'

  got_=$(echo '{"ok":true,"data":{"foo":1}}' | era.Unwrap | jq -c .) || {
    tesht.Log 'envelope success returned nonzero exit'
    return 1
  }

  [[ $got_ == "$want" ]] || {
    tesht.Log "envelope success body mismatch: got: $got_"
    return 1
  }
}

IFS=$'\n'
set -o noglob
set -uo pipefail

return 2>/dev/null

set -e
test_unwrap_envelopeSuccess_objectData
