#!/usr/bin/env bash
# 按 GitHub 的 step 门禁语义重放整条 step 链，而不是抽出某一格的 shell 块。
#
# GitHub 有两条规则，谁也没写在 `if:` 里：
#   1. step 的 `if` 不含状态函数（success / failure / cancelled / always）时，
#      实际判据是 `success() && <你写的条件>`；
#   2. `success()` 只要前面有 step 失败过就是假 —— 被跳过的 step 不算失败。
# 抽单个 shell 块的测试看不见这两条：块里断言 `run_codex=true` 可以通过，而真
# 跑起来那之后的每一步都被跳过。MEL-199 的 F1 就是这么漏过去的。
#
# 用法：
#   gate_reset
#   gate_set inputs.review_fixer codex          # 喂 if 里引用到的值
#   gate_set steps.gate.outputs.run true
#   gate_fails 'Check the fix outcome'          # 声明哪一步跑起来会失败
#   gate_if 'Check the fix outcome' "<expr>"    # 覆写某一步的 if（造回归场景用）
#   gate_trace "$WF"
#   gate_ran 'Codex fixes the PR'               # 断言
#   gate_skipped 'Check the fix outcome'
#
# 看不懂的 `if` 表达式一律报错退出，绝不当成真 —— 否则以后有人写了新写法，
# 这套模型会安安静静地继续打绿勾。

GATE_CTX=''
GATE_FAILS=''
GATE_IFS_OVERRIDE=''
GATE_TRACE=''
GATE_JOB_FAILED=false

gate_reset() {
  GATE_CTX=''
  GATE_FAILS=''
  GATE_IFS_OVERRIDE=''
  GATE_TRACE=''
  GATE_JOB_FAILED=false
}

# gate_set <ref> <value>，如 gate_set steps.select.outputs.first codex
gate_set() {
  GATE_CTX="$GATE_CTX
$1=$2"
}

# 没设过的引用一律读成空串，同 GitHub 对未赋值 output 的处理。
gate_get() {
  printf '%s\n' "$GATE_CTX" |
    awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { print v }'
}

# 某一步被跳过时，它声明过的 outputs 要跟着作废 —— 跳过的 step 不会产出任何值。
gate_drop_outputs() {
  GATE_CTX="$(printf '%s\n' "$GATE_CTX" | awk -v p="steps.$1.outputs." 'index($0, p) != 1')"
}

gate_fails() {
  GATE_FAILS="$GATE_FAILS|$1|"
}

gate_if() {
  GATE_IFS_OVERRIDE="$GATE_IFS_OVERRIDE
$1	$2"
}

gate_trim() {
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

gate_has_status() {
  case "$1" in
    *'success()'* | *'always()'* | *'failure()'* | *'cancelled()'*) return 0 ;;
  esac
  return 1
}

# gate_term <term> → 0 真 / 1 假 / 2 看不懂
gate_term() {
  local t ref op lit actual
  t="$(gate_trim "$1")"
  case "$t" in
    'success()')
      if [ "$GATE_JOB_FAILED" = true ]; then return 1; fi
      return 0
      ;;
    'failure()')
      if [ "$GATE_JOB_FAILED" = true ]; then return 0; fi
      return 1
      ;;
    'always()' | '!cancelled()') return 0 ;;
    'cancelled()') return 1 ;;
  esac

  case "$t" in
    *' == '*) op='=='; ref="${t%% == *}"; lit="${t#* == }" ;;
    *' != '*) op='!='; ref="${t%% != *}"; lit="${t#* != }" ;;
    *) return 2 ;;
  esac
  ref="$(gate_trim "$ref")"
  lit="$(gate_trim "$lit")"
  case "$lit" in
    "'"*"'") lit="${lit#\'}"; lit="${lit%\'}" ;;
    *) return 2 ;;
  esac
  case "$ref" in
    steps.* | inputs.* | github.*) actual="$(gate_get "$ref")" ;;
    *) return 2 ;;
  esac
  if [ "$op" = '==' ]; then
    [ "$actual" = "$lit" ]
  else
    [ "$actual" != "$lit" ]
  fi
}

# gate_eval <expr> → 0 真 / 1 假 / 2 看不懂。&& 和 || 混用直接判看不懂：
# 本仓库没有这种写法，与其猜优先级，不如让测试红。
gate_eval() {
  local expr rest term rc any
  expr="$(gate_trim "$1")"
  expr="${expr#\$\{\{}"
  expr="${expr%\}\}}"
  expr="$(gate_trim "$expr")"
  [ -n "$expr" ] || return 0

  case "$expr" in
    *'&&'*)
      case "$expr" in *'||'*) return 2 ;; esac
      rest="$expr"
      while [ -n "$rest" ]; do
        case "$rest" in
          *'&&'*) term="${rest%%&&*}"; rest="${rest#*&&}" ;;
          *) term="$rest"; rest='' ;;
        esac
        gate_term "$term" || return $?
      done
      return 0
      ;;
    *'||'*)
      any=1
      rest="$expr"
      while [ -n "$rest" ]; do
        case "$rest" in
          *'||'*) term="${rest%%||*}"; rest="${rest#*||}" ;;
          *) term="$rest"; rest='' ;;
        esac
        if gate_term "$term"; then rc=0; else rc=$?; fi
        [ "$rc" -ne 2 ] || return 2
        [ "$rc" -ne 0 ] || any=0
      done
      return "$any"
      ;;
  esac
  gate_term "$expr"
}

# 从 workflow 里按顺序抽出每一步的 name / id / if / continue-on-error。
# `- uses:` 开头的步骤也算一步，名字记成 `uses: <action>`。
gate_steps() {
  awk '
    function flush() { if (have) printf "%s\t%s\t%s\t%s\n", name, id, cond, coe }
    /^      - name: / { flush(); have = 1; name = substr($0, 15); id = ""; cond = ""; coe = ""; next }
    /^      - uses: / { flush(); have = 1; name = "uses: " substr($0, 15); id = ""; cond = ""; coe = ""; next }
    have && /^        id: /                { id   = substr($0, 13); next }
    have && /^        if: /                { cond = substr($0, 13); next }
    have && /^        continue-on-error: / { coe  = substr($0, 28); next }
    END { flush() }
  ' "$1"
}

gate_override_for() {
  printf '%s\n' "$GATE_IFS_OVERRIDE" |
    awk -F'\t' -v k="$1" '$1 == k { v = $2; found = 1 } END { if (found) print v; else exit 1 }'
}

# gate_trace <workflow>：走完整条链，结果留在 $GATE_TRACE，每行 `run|skip <name>`。
gate_trace() {
  local wf="$1" name id cond coe eff runs rc outcome over
  case "$wf" in /*) ;; *) wf="$REPO_ROOT/$wf" ;; esac
  [ -f "$wf" ] || { echo "gate_trace: no workflow file $wf" >&2; return 98; }

  GATE_JOB_FAILED=false
  GATE_TRACE=''

  while IFS="$(printf '\t')" read -r name id cond coe; do
    [ -n "$name" ] || continue
    eff="$cond"
    if over="$(gate_override_for "$name")"; then eff="$over"; fi

    runs=true
    # 不含状态函数 = GitHub 隐式补一个 success()。整条模型的要害就在这三行。
    if ! gate_has_status "$eff"; then
      [ "$GATE_JOB_FAILED" = false ] || runs=false
    fi
    if [ "$runs" = true ] && [ -n "$eff" ]; then
      if gate_eval "$eff"; then rc=0; else rc=$?; fi
      if [ "$rc" -eq 2 ]; then
        echo "gate_trace: unsupported if expression on '$name': $eff" >&2
        return 98
      fi
      [ "$rc" -eq 0 ] || runs=false
    fi

    if [ "$runs" = true ]; then
      outcome=success
      case "$GATE_FAILS" in *"|$name|"*) outcome=failure ;; esac
      if [ "$outcome" = failure ] && [ "$coe" != true ]; then GATE_JOB_FAILED=true; fi
      GATE_TRACE="$GATE_TRACE
run $name"
    else
      outcome=skipped
      [ -z "$id" ] || gate_drop_outputs "$id"
      GATE_TRACE="$GATE_TRACE
skip $name"
    fi
    [ -z "$id" ] || gate_set "steps.$id.outcome" "$outcome"
  done <<EOF
$(gate_steps "$wf")
EOF
}

gate_ran() {
  case "$GATE_TRACE" in
    *"
run $1"*) return 0 ;;
  esac
  printf 'expected this step to RUN: %s\ntrace:%s\n' "$1" "$GATE_TRACE" >&2
  return 1
}

gate_skipped() {
  case "$GATE_TRACE" in
    *"
skip $1"*) return 0 ;;
  esac
  printf 'expected this step to be SKIPPED: %s\ntrace:%s\n' "$1" "$GATE_TRACE" >&2
  return 1
}
