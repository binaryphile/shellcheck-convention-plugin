#!/usr/bin/env bash

IFS=$'\n'
set -o noglob

test_unwrap_envelopeSuccess_objectData() {
  local got_
  if ! got_=$(echo '{"ok":true,"data":{"foo":1}}' | era.Unwrap | jq -c .); then
    tesht.Log "envelope success returned nonzero exit"
    return 1
  fi
  if [[ $got_ != '{"foo":1}' ]]; then
    tesht.Log "envelope success body mismatch: got: $got_"
    return 1
  fi
  return 0
}
