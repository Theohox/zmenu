#!/usr/bin/env bats

# Security-focused tests

setup() {
    ./build.sh
}

@test "private temp directory is created" {
    run bash -c './zmenu.sh --run dashboard </dev/null >/dev/null 2>&1; test -d ~/.zmenu/tmp'
    [ "$status" -eq 0 ]
}

@test "error log is created under private temp" {
    run bash -c './zmenu.sh --run dashboard </dev/null >/dev/null 2>&1; test -f ~/.zmenu/tmp/zmenu-errors.log'
    [ "$status" -eq 0 ]
}

@test "no predictable /tmp paths for sensitive files" {
    run grep -R 'ZMENU_CONTEXT_FILE="/tmp' src/
    [ "$status" -ne 0 ]
    run grep -R 'ZMENU_ERROR_LOG="/tmp' src/
    [ "$status" -ne 0 ]
}
