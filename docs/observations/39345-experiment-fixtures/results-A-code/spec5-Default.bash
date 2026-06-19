#!/usr/bin/env bash

IFS=$'\n'
set -o noglob

setupTempRepo() {
    local tmpdir_
    tmpdir_=$(mktemp -d)

    (
        cd "$tmpdir_" || exit 1
        git init --quiet 2>/dev/null
        git config user.email "t@t"
        git config user.name "t"
        git config core.hooksPath .git/hooks
        git config commit.gpgsign false
        ln -s $Hook .git/hooks/pre-commit
    )

    printf '%s' "$tmpdir_"
}
