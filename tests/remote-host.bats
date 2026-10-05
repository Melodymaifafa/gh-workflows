#!/usr/bin/env bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/remote-host.sh"
}

@test "https remote" {
  run "$SCRIPT" https://github.com/Melodymaifafa/gh-workflows.git
  [ "$status" -eq 0 ]
  [ "$output" = "github.com" ]
}

@test "ssh remote" {
  run "$SCRIPT" git@github.com:Melodymaifafa/gh-workflows.git
  [ "$status" -eq 0 ]
  [ "$output" = "github.com" ]
}

@test "https remote with an at sign in its path" {
  run "$SCRIPT" https://mirror.example/org@github.com/repo.git
  [ "$status" -eq 0 ]
  [ "$output" = "mirror.example" ]
}

@test "ssh URL with a bracketed IPv6 host and port" {
  run "$SCRIPT" 'ssh://git@[2001:db8::1]:2222/org/repo.git'
  [ "$status" -eq 0 ]
  [ "$output" = "[2001:db8::1]" ]
}

@test "no url is an error" {
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}
