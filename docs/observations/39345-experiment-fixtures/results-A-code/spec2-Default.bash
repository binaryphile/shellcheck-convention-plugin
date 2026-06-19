#!/usr/bin/env bash

IFS=$'\n'
set -o noglob

assert() {
    local message=$1
    local condition=$2

    if eval $condition; then
        Pass=$((Pass + 1))
        printf '\033[32mPASS\033[0m  %s\n' $message
    else
        Failed=$((Failed + 1))
        printf '\033[31mFAIL\033[0m  %s\n' $message
    fi
}
