#!/usr/bin/env bash
# tests/bdw-sync-mutants.sh — 不変条件↔検証の「非空虚性」を named mutant で機械実証する。
#
# un-10h5 契約(DONE gate): 「不変条件↔検証 各行に … 反転 named mutant『mutant 適用で当該 case が
# FAIL する』ログ … を必須化」。本 harness は bin/bdw / bin/bdw-sync の named mutant を 1 つずつ
# 適用した copy を作り、対応する tests/bdw-sync.bats のテストを BDW_OVERRIDE/BDW_SYNC_OVERRIDE で
# その mutated copy に差し向けて実行し、**元は PASS するテストが mutant で FAIL する**ことを確認する。
# 全 mutant が期待どおり差分を出せば exit 0(検証は非空虚)。1 つでも mutant がテストを壊せなければ
# そのテストは vacuous → exit 1。
#
# 不変条件 ↔ mutant ↔ 対応テスト:
#   ⑥ conflict→block  : M1 conflict 分類を削除(→transient)     : invariant6-conflict
#   ⑥ transient→degrade: M2 transient を CONFLICT に反転        : invariant6-transient
#   ⑦ noremote noop    : M3 has_remote 常に真                    : invariant7-noremote
#   ⑤ throttle         : M4 marker_is_fresh 常に stale           : invariant5-throttle-fresh
#   ⑤ marker disjoint  : M5 marker を .beads/last-sync に        : invariant5-marker-disjoint
#   ① 自台帳のみ        : M6 pull に -C /foreign を注入            : invariant1-self-only
#   bdw block          : M7 bin/bdw の exit3 block を無効化       : bdw-block
#   Layer3 lock 直列化 : M8 run_locked の flock 失敗 skip を反転   : lock-coordination

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
BATS_FILE="$HERE/bdw-sync.bats"
command -v bats >/dev/null 2>&1 || { echo "FAIL: bats absent (core tool・skip 禁止)"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bdw-mutants-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
LOG="${BDW_MUTANT_LOG:-$WORK/mutant-differential.log}"
: > "$LOG"

fails=0
# run_mutant <name> <target: bdw|bdw-sync> <sed-expr> <bats-test-name> <invariant-label>
run_mutant() {
  local name="$1" target="$2" sed_expr="$3" testname="$4" label="$5"
  local md="$WORK/$name"; mkdir -p "$md/bin"
  cp "$ROOT/bin/bdw" "$md/bin/bdw"
  cp "$ROOT/bin/bdw-sync" "$md/bin/bdw-sync"
  chmod +x "$md/bin/bdw" "$md/bin/bdw-sync"
  # mutant を適用
  sed -i "$sed_expr" "$md/bin/$target"
  # 適用後も構文が壊れていないこと(壊れた mutant は差分の根拠にならない)
  if ! bash -n "$md/bin/$target" 2>/dev/null; then
    echo "  [$name] MUTANT が構文破壊 → 無効な mutant(要修正)" | tee -a "$LOG"
    fails=$((fails+1)); return
  fi
  # mutated copy に差し向けて対象テストのみ実行。元は PASS するテストが FAIL するはず。
  # filter は bats の非アンカー正規表現。testname は括弧等の regex-special を含まない一意 prefix を渡す
  # (アンカー ^..$ + 括弧付き名は regex group と解釈され 0 件マッチ→誤 PASS になるため使わない)。
  local out rc ntests
  out="$(BDW_OVERRIDE="$md/bin/bdw" BDW_SYNC_OVERRIDE="$md/bin/bdw-sync" \
         bats "$BATS_FILE" --filter "$testname" 2>&1)"; rc=$?
  # filter が 1 件以上マッチしたことを確認(0 件マッチは差分の根拠にならない=harness bug)。
  ntests="$(printf '%s\n' "$out" | grep -cE '^(ok|not ok) ')"
  if [ "$ntests" -lt 1 ]; then
    echo "  [$name] filter '$testname' が 0 件マッチ(harness bug)" | tee -a "$LOG"
    fails=$((fails+1)); return
  fi
  if [ "$rc" -ne 0 ]; then
    { echo "MUTANT-DIFF ok  [$name/$label] mutant 適用で '$testname' が FAIL(=検証は非空虚)"
      printf '%s\n' "$out" | grep -E '^(not ok|#)' | sed 's/^/    /' | head -6
    } | tee -a "$LOG"
  else
    { echo "MUTANT-DIFF FAIL[$name/$label] mutant 適用でも '$testname' が PASS(=テストが vacuous!)"
    } | tee -a "$LOG"
    fails=$((fails+1))
  fi
}

echo "== bdw-sync mutant differential(不変条件↔検証 非空虚性)==" | tee -a "$LOG"

# M1: classify の CONFLICT 分岐行を削除 → conflict が TRANSIENT 落ち(exit 0)。
run_mutant M1-conflict-to-transient bdw-sync \
  "/require operator resolution/d" \
  "invariant6-conflict" "⑥conflict"

# M2: classify 末尾の TRANSIENT を CONFLICT に反転 → transient が exit 3。
run_mutant M2-transient-to-conflict bdw-sync \
  "s/  printf 'TRANSIENT'/  printf 'CONFLICT'/" \
  "invariant6-transient" "⑥transient"

# M3: has_remote を常に真に → remote 未設定でも pull を試みる。
run_mutant M3-has-remote-always bdw-sync \
  "s/^has_remote() {/has_remote() { return 0; :/" \
  "invariant7-noremote" "⑦noremote"

# M4: marker_is_fresh を常に stale(return 1)に → fresh でも pull。
run_mutant M4-throttle-off bdw-sync \
  "s/^marker_is_fresh() {/marker_is_fresh() { return 1; :/" \
  "invariant5-throttle-fresh" "⑤throttle"

# M5: 既定 marker を禁則 .beads/last-sync に → disjoint 検証が FAIL。
run_mutant M5-marker-forbidden bdw-sync \
  "s#  printf '%s/bd-sync-%s.marker' \"\$ld\" \"\$rid\"#  printf '%s/.beads/last-sync' \"\$PWD\"#" \
  "invariant5-marker-disjoint" "⑤marker-disjoint"

# M6: pull に foreign flag(-C /foreign)を注入 → 自台帳のみ検証が FAIL。
run_mutant M6-foreign-flag bdw-sync \
  's#out="\$(bd_net "\$BD_BIN" dolt pull 2>&1)"#out="$(bd_net "$BD_BIN" -C /foreign dolt pull 2>\&1)"#' \
  "invariant1-self-only" "①self-only"

# M7: bin/bdw の「sync exit 3 で block」を無効化 → WRITE が block されず bd が走る。
run_mutant M7-no-block bdw \
  's/if \[ "\$sync_rc" -eq 3 \]; then/if false; then/' \
  "bdw-block" "bdw-block"

# M8: run_locked の flock 取得失敗 skip(return 0)を no-op に反転 → lock 保持中でも no-lock で実行。
#     Layer3 --lock が worker lock を無視して push する fail-open 回帰を lock-coordination が捕まえる。
run_mutant M8-lock-fail-open bdw-sync \
  's/flock 取得失敗 — skip(次回 timer で回収)" >&2; return 0; }/flock 取得失敗 — skip(次回 timer で回収)" >\&2; : ; }/' \
  "lock-coordination" "run_locked-lock-fail"

echo "----" | tee -a "$LOG"
if [ "$fails" -eq 0 ]; then
  echo "MUTANT DIFFERENTIAL: PASS(全 mutant が対応テストを FAIL させた=検証は非空虚)" | tee -a "$LOG"
  echo "log: $LOG"
  exit 0
else
  echo "MUTANT DIFFERENTIAL: FAIL($fails 件・vacuous または無効 mutant)" | tee -a "$LOG"
  echo "log: $LOG"
  exit 1
fi
