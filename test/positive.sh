#!/usr/bin/env bash
# Fixture: each block must trip exactly the matching SC9xxx convention check.

# SC9001: taint-suffix variable used unquoted in a splitting context.
var_=$(printf foo)
echo $var_

# SC9002: command substitution assigned to a non-taint variable; cat is not allowlisted.
content=$(cat /etc/hostname)

# SC9003: non-taint variable quoted under IFS/noglob (quoting is unnecessary).
plain=hello
echo "$plain"

# SC9004: '_' taint suffix and 'List' suffix are mutually exclusive.
hostList_=foo

# SC9005: numeric comparison in [[ ]]; bash-style-guide §7 says use (( )).
rc=$?
[[ $rc -eq 0 ]] && echo ok

# SC9006: identifier contains the legacy whitelist/blacklist substring.
whitelist=()
blacklistFn() { :; }

# SC9006-comments: legacy term in comment text (#7739).
# avoid using whitelist; prefer allowlist instead
echo ok

# SC9007: docstring above function doesn't start with the function name.
# Helper that frobs the input
docfn() { :; }

# SC9008: List-suffixed variable initialized as a string, not array.
xList=foo
