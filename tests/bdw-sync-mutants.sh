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
#   ⑦ 複合 scheme(L1)  : M9a scheme 照合を旧 [a-z]+:// へ revert   : scheme-git-https-pull
#   ⑦ 複合 scheme(L3)  : M9b 同上(push 経路を独立に保証)          : scheme-git-https-push
#   ⑦ over-match 制御  : M10 scheme 照合を何でも通るに緩める      : scheme-no-url
#   subdir 台帳 fix    : M11 resolve_export_root walk-up を no-op  : export-root-subdir-ledger
#   (un-xywb)            (物理 DB 検出を常に不成立=旧 dirname(common-dir)へ revert)
#   worktree 非回帰    : M12 marker を「.beads あれば match」に緩め : export-root-worktree-noregress
#   marker 選定        (物理 DB gate 撤廃=metadata.json checkout で worktree 誤選択)
#   越境ガード escape  : M13 toplevel break を no-op(境界を無効化)   : export-root-boundary-escape
#   (un-xywb)            (walk-up が toplevel を越え親の物理 DB へ誤収束=escape)
#   多段上昇の非空虚   : M14 上昇段 dir="$parent" を dir="$toplevel" へ : export-root-subdir-deep
#   (un-xywb)            (中間 dir を skip=看板の walk-up 上昇段そのものを潰し親へ escape)

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

# M9: has_remote の scheme 照合を修正前の素朴な [a-z]+:// へ revert → 複合 scheme(git+https://)が
#     NO-MATCH に戻り、remote 有りでも do_pull/do_push が no-op 枝に落ちて dolt を呼ばない(un-l3ln)。
#     ＝「修正前 FAIL / 修正後 PASS」の対称実証(新 case の非空虚性の機械保証)。
#     ★pull/push を 1 filter に束ねない: run_mutant の判定は bats の集約 rc(:60)のみで、filter が
#       複数 case にマッチすると片方 FAIL でも ok と記録される=もう片方が将来 vacuous 化しても
#       緑のまま通る。Layer1/Layer3 の各経路を独立に機械保証するため 2 呼出しへ分ける。
SCHEME_REVERT='s#\[a-z\]\[A-Za-z0-9+.-\]\*://#[a-z]+://#'
run_mutant M9a-scheme-revert-pull bdw-sync "$SCHEME_REVERT" \
  "scheme-git-https-pull" "⑦scheme-composite(L1)"
run_mutant M9b-scheme-revert-push bdw-sync "$SCHEME_REVERT" \
  "scheme-git-https-push" "⑦scheme-composite(L3)"

# M10: scheme 照合を「何でも通る」へ緩める(over-match 方向) → URL でない行まで remote 有りと誤認し
#      no-op すべき場面で dolt を呼ぶ。M9 は under-match 方向のみを守るため、FENCE-2 が要求する
#      「^ アンカーと name 列を維持(over-match 回帰なし)」側は本 mutant が担う。
#      ★M3(has_remote 常に真)は代替にならない: 対応する invariant7-noremote は手前の
#        'No remotes configured' 短絡で拾われ scheme 正規表現に構造的に盲目(実測)。ゆえに
#        over-match は scheme-no-url でしか捕まらず、その非空虚性は本 mutant でのみ機械保証される。
run_mutant M10-scheme-overmatch bdw-sync \
  "s#grep -qE '\^[^']*'#grep -qE '.'#" \
  "scheme-no-url" "⑦scheme-overmatch"

# M11: resolve_export_root の walk-up を no-op 化(物理 DB 検出を常に不成立=return 1)→ 空振り fallback で
#   旧 dirname(common-dir)へ revert。subdir 台帳では親 root へ誤解決し auto-export が親 mirror を指す
#   =「修正前 FAIL / 修正後 PASS」の対称実証(un-xywb 新 case の非空虚性の機械保証)。
run_mutant M11-export-root-revert bdw \
  's/^_bdw_beads_has_physical_db() {/_bdw_beads_has_physical_db() { return 1; :/' \
  "export-root-subdir-ledger" "subdir-export-root(un-xywb)"

# M12: 物理 DB gate を撤廃し「.beads があれば台帳 root」に緩める(over-match) → worktree checkout に来る
#   tracked ファイル(metadata.json 等)だけの .beads を worktree で誤選択し、worktree→anchor 収束を破る。
#   marker を物理 DB dir 限定にした load-bearing 判断(metadata.json 除外)の非空虚性を worktree 側で機械保証。
run_mutant M12-export-root-any-beads bdw \
  's/^_bdw_beads_has_physical_db() {/_bdw_beads_has_physical_db() { [ -d "$1\/.beads" ]; return; :/' \
  "export-root-worktree-noregress" "worktree-noregress(un-xywb)"

# M13: walk-up の toplevel 境界 break を no-op 化(境界を無効化)→ walk-up が git toplevel を越えて親側の
#   物理 DB(OUTER/.beads/embeddeddolt)を発見し escape する。escape 防止の安全境界(git 管理外/$HOME/.beads
#   への越境禁止=fence :140-142 の load-bearing 不変量)の非空虚性を、越境退行を検出する形で機械保証する。
#   ★M11/M12 は fix 本体(walk-up 発火・marker 選定)を守るが安全境界は守らない: 既存 2 case は境界を外しても
#     FAIL しない(subdir は SUB で即 return し break 未通過 / worktree は WT→ANCHOR で同じ ANCHOR を返す)。
run_mutant M13-export-root-no-boundary bdw \
  's/\[ "$dir" = "$toplevel" \] && break/:/' \
  "export-root-boundary-escape" "boundary-escape(un-xywb)"

# M14: walk-up の上昇段 dir="$parent"(1 段ずつ上る)を dir="$toplevel"(全中間 dir を一気に skip)へ変異 → cwd が
#   台帳 root より深い subdir にあるとき、中間の真の台帳 root($SUB)を跨いで toplevel($PARENT)へ escape する。
#   看板機構「$PWD..git toplevel の bounded walk-up」の【上昇段そのもの】の非空虚性を機械保証する(この上昇を
#   通る realistic modality=深い cwd を既存 ①/②/②'/③ が一つも張っていなかった=上昇段が無検証だった穴を塞ぐ)。
#   ★M11–M13 はこの mutant を代替しない: いずれも cwd==台帳 root か cwd==toplevel で即 return/即 break のため
#     上昇段を一度も通らず、dir="$toplevel" 変異でも同じ export root を返して PASS のままだった(export-root-subdir-deep
#     でのみ FAIL する)。
run_mutant M14-export-root-skip-ascent bdw \
  's/dir="$parent"/dir="$toplevel"/' \
  "export-root-subdir-deep" "subdir-deep-ascent(un-xywb)"

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
