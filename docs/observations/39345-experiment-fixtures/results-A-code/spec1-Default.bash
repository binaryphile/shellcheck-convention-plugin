#!/usr/bin/env bash

IFS=$'\n'
set -o noglob

installMocks() {
    local log_file=$1

    : > $log_file
    export MOCK_LOG=$log_file

    systemctl() {
        echo "systemctl $*" >> $MOCK_LOG
        return 0
    }

    sudo() {
        echo "sudo $*" >> $MOCK_LOG
        return 0
    }

    sqlite3() {
        echo "sqlite3 $*" >> $MOCK_LOG
        return 0
    }

    curl() {
        echo "curl $*" >> $MOCK_LOG
        return 0
    }

    era() {
        echo "era $*" >> $MOCK_LOG
        return 0
    }

    waitForHealth() {
        return 0
    }

    export -f systemctl sudo sqlite3 curl era waitForHealth
}
