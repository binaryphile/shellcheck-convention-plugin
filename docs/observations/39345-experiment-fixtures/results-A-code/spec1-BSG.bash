#!/usr/bin/env bash
# Naming Policy:
#
# This is a standalone script — no namespace prefix on functions, no suffix on globals.
# Function names use camelCase (helpers / private style).
# Local variable names begin with lowercase, e.g. localVariable.
# Global variable names begin with uppercase, e.g. GlobalVariable.
# Variables ending in _ may contain IFS characters or be empty; must be
# quoted on use. *List / *Lists suffix is the multi-value alternative.

# installMocks truncates the given log file, exports its path as MockLog,
# and installs exported function shims that record their invocations to
# the log so the system under test can be exercised hermetically. The
# shims for systemctl, sudo, sqlite3, curl, and era each append one line
# of the form "<cmd> <space-joined-args>" and return 0; waitForHealth is
# stubbed to return 0 without logging.
installMocks() {
  local logfile=$1

  : >$logfile
  export MockLog=$logfile

  systemctl() { echo "systemctl $*" >>$MockLog; }
  sudo()      { echo "sudo $*"      >>$MockLog; }
  sqlite3()   { echo "sqlite3 $*"   >>$MockLog; }
  curl()      { echo "curl $*"      >>$MockLog; }
  era()       { echo "era $*"       >>$MockLog; }
  waitForHealth() { return 0; }

  export -f systemctl sudo sqlite3 curl era waitForHealth
}
