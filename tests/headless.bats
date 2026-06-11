#!/usr/bin/env bats

# Headless / --run mode smoke tests

setup() {
    ./build.sh
}

@test "--run dashboard works without TTY" {
    run bash -c 'unset TERM; echo "" | ./zmenu.sh --run dashboard'
    [ "$status" -eq 0 ]
    [[ "$output" == *"DASHBOARD"* ]]
}

@test "--run mod_kill_mode renders without TTY" {
    run bash -c 'unset TERM; echo "" | ./zmenu.sh --run mod_kill_mode'
    [ "$status" -eq 0 ]
    [[ "$output" == *"KILL MODE"* ]]
}

@test "--run mod_security is reachable and quits cleanly" {
    run bash -c 'unset TERM; printf "q\n" | ./zmenu.sh --run mod_security'
    [ "$status" -eq 0 ]
    [[ "$output" == *"SECURITY & PRIVACY"* ]]
}

@test "--run mod_maintenance is reachable and quits cleanly" {
    run bash -c 'unset TERM; printf "q\n" | ./zmenu.sh --run mod_maintenance'
    [ "$status" -eq 0 ]
    [[ "$output" == *"MAINTENANCE"* ]]
}

@test "config permission enforcement blocks overly permissive config" {
    run bash -c '
        chmod 644 ~/.zmenu/config
        ./zmenu.sh --run dashboard </dev/null >/dev/null 2>&1
        rc=$?
        chmod 600 ~/.zmenu/config
        exit $rc
    '
    [ "$status" -eq 1 ]
}
