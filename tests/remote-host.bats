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

@test "no url is an error" {
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}
