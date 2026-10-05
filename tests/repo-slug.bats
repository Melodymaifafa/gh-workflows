#!/usr/bin/env bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/repo-slug.sh"
}

@test "https remote" {
  run "$SCRIPT" https://github.com/Melodymaifafa/gh-workflows.git
  [ "$status" -eq 0 ]
  [ "$output" = "Melodymaifafa/gh-workflows" ]
}

@test "ssh remote" {
  run "$SCRIPT" git@github.com:Melodymaifafa/gh-workflows.git
  [ "$status" -eq 0 ]
  [ "$output" = "Melodymaifafa/gh-workflows" ]
}

@test "ssh:// remote" {
  run "$SCRIPT" ssh://git@github.com/Melodymaifafa/gh-workflows.git
  [ "$status" -eq 0 ]
  [ "$output" = "Melodymaifafa/gh-workflows" ]
}

@test "remote without .git suffix" {
  run "$SCRIPT" https://github.com/Melodymaifafa/gh-workflows
  [ "$status" -eq 0 ]
  [ "$output" = "Melodymaifafa/gh-workflows" ]
}

@test "host is matched case-insensitively, owner/repo keeps its case" {
  run "$SCRIPT" https://GitHub.com/Melodymaifafa/gh-workflows.git
  [ "$status" -eq 0 ]
  [ "$output" = "Melodymaifafa/gh-workflows" ]

  run "$SCRIPT" git@GITHUB.COM:Melodymaifafa/gh-workflows.git
  [ "$status" -eq 0 ]
  [ "$output" = "Melodymaifafa/gh-workflows" ]
}

@test "uppercase lookalike host is still an error" {
  run "$SCRIPT" https://NOTGITHUB.COM/o/r.git
  [ "$status" -eq 1 ]
}

@test "dot-only components are an error" {
  run "$SCRIPT" https://github.com/../victim.git
  [ "$status" -eq 1 ]

  run "$SCRIPT" https://github.com/o/..
  [ "$status" -eq 1 ]

  run "$SCRIPT" git@github.com:./r.git
  [ "$status" -eq 1 ]
}

@test "dots inside a repo name are fine" {
  run "$SCRIPT" https://github.com/o/my.repo.git
  [ "$status" -eq 0 ]
  [ "$output" = "o/my.repo" ]
}

@test "no url is an error" {
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "non-github host is an error" {
  run "$SCRIPT" https://example.com/o/r.git
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
}

@test "lookalike github host is an error" {
  run "$SCRIPT" https://notgithub.com/o/r.git
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
}

@test "url without a repo segment is an error" {
  run "$SCRIPT" https://github.com/Melodymaifafa
  [ "$status" -eq 1 ]
}

@test "url with extra path segments is an error" {
  run "$SCRIPT" https://github.com/Melodymaifafa/gh-workflows/tree/main
  [ "$status" -eq 1 ]
}
