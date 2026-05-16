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
