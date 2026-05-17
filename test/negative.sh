#!/usr/bin/env bash
# Fixture: none of SC9001-SC9004 must fire on these patterns.

# Taint-suffixed variable properly quoted: SC9001 silent.
var_=foo
echo "$var_"

# Cmdsub assigned to a taint-suffixed variable: SC9002 silent.
content_=$(cat /etc/hostname)

# Cmdsub allowlisted command (hostname): SC9002 silent.
host=$(hostname)

# Non-taint variable used unquoted under IFS/noglob: SC9003 silent.
plain=hello
echo $plain

# List suffix without '_' taint suffix: SC9004 silent.
hostList=foo

# SC9005-silent: string emptiness and file/path tests still belong in [[ ]].
x=
[[ -z $x ]] && echo empty
[[ -f /etc/hostname ]] && echo file
[[ $x == foo ]] && echo eq
# Arithmetic form is the recommended replacement.
rc=$?
(( rc == 0 )) && echo ok

# SC9006-silent: inclusive forms and unrelated names.
allowlist=()
denylistFn() { :; }
neutral=hello

# SC9006-comments-silent: comment using inclusive forms only (#7739).
# prefer the allowlist / denylist terminology
echo ok

# SC9007-silent: docstring's first word matches the function name.

# docfn frobs the input
docfn() { :; }

# Function with no docstring at all: also silent (nothing to validate).

bareFn() { :; }
