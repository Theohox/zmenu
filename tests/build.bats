#!/usr/bin/env bats

# Build and syntax validation tests

@test "build.sh produces zmenu.sh" {
    rm -f zmenu.sh
    run ./build.sh
    [ "$status" -eq 0 ]
    [ -f zmenu.sh ]
    [ -x zmenu.sh ]
}

@test "built script passes bash -n" {
    run bash -n zmenu.sh
    [ "$status" -eq 0 ]
}

@test "build is reproducible (same bytes for same sources)" {
    ./build.sh
    cp zmenu.sh zmenu.sh.first
    ./build.sh
    diff -q zmenu.sh zmenu.sh.first
    rm -f zmenu.sh.first
}

@test "no hard-coded /tmp/zmenu paths remain" {
    run grep -R '/tmp/zmenu' src/
    [ "$status" -ne 0 ]
}

@test "no runtime eval in discovery or apply engine" {
    run bash -c 'grep -R "\beval\b" src/ | grep -Ev "\.sh:[[:space:]]*#" || true'
    [ -z "$output" ]
}
