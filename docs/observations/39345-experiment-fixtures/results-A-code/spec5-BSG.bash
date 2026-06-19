IFS=$'\n'
set -o noglob

# Naming Policy:
#
# Library helper for test setup — function names use camelCase (private).
# Global variable names begin with uppercase, e.g. Hook.
# Local variable names begin with lowercase, e.g. tempDir.
# Variables ending in _ may contain IFS characters or be empty; must be
# quoted on use.

# setupTempRepo creates a hermetic git repo with `Hook` symlinked as pre-commit.
#
# Reads global `Hook` (absolute path to hook file). Creates a temp dir via
# `mktemp -d`, initializes git quietly, sets user identity and overrides
# inherited `core.hooksPath` plus `commit.gpgsign` so the hook fires without
# prompting external signing tools. Prints the temp dir's absolute path to
# stdout with no trailing newline. Caller owns cleanup.
setupTempRepo() {
  local tempDir_
  tempDir_=$(mktemp -d)

  git -C "$tempDir_" init -q -b main
  git -C "$tempDir_" config user.email t@t
  git -C "$tempDir_" config user.name t
  git -C "$tempDir_" config core.hooksPath .git/hooks
  git -C "$tempDir_" config commit.gpgsign false

  ln -s $Hook "$tempDir_/.git/hooks/pre-commit"

  printf %s "$tempDir_"
}
