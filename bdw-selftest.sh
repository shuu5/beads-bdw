#!/usr/bin/env bash
# bdw-selftest.sh — race/selftest for bin/bdw (canonical beads-bdw SSOT)
#
# PROVENANCE: scriptorium scripts/bdw-selftest.sh を port(さらにその元 = uns・bd un-gmq AC2)。
#   harness は throwaway な mktemp git+bd repo だけを使い実 .beads 台帳を触らないため repo 非依存。
#   $HERE/bin/bdw を解決して同梱 canonical bdw の直列化を実証する。
#
# 証明する命題:
#   RED  : bdw 無しの並列 write(同一 issue への append-notes)は lost-update する(hazard 実在)。
#   GREEN: bdw 経由の並列 write は flock 直列化で全件残る(lost-update しない)。
#   READ : write-lock を別プロセスが排他保持中でも、bdw の READ は lock を待たず即時素通し
#          する。同時に、同じ lock を bdw の WRITE は待つ(timeout で打ち切られる)ことを
#          positive control とし、保持した lock が「bdw が実際に使う lock」であることを担保
#          する(lock 配線ミスで READ がたまたま速いだけ、を排除する)。
#   LOCKDIR : `bdw lock-dir` が解決済み lock_dir を stdout に出して exit 0(consumer contract)。
#   GUARDBN : 実行ファイルの basename が "bd" でない(guard が basename!="bd" を素通しする性質)。
#
# 最重要安全制約: 実 .beads 台帳を絶対に触らない。
#   本テストは mktemp の throwaway な git+bd repo だけを使い、書込前に `bd context` の
#   repo root が temp dir 配下であることを検証する。一致しなければ即 ABORT(書込まない)。
#
# 3 値判定(RED→GREEN の対比が成立して初めて PASS と言い切る):
#   PASS(exit 0)         : RED 再現(s<N) ∧ GREEN==N ∧ READ 素通し ∧ LOCKDIR ∧ GUARDBN ok
#   INCONCLUSIVE(exit 2) : hard 次元(GREEN/READ/LOCKDIR/GUARDBN)は全 ok だが RED 非再現(timing)
#                          = hazard を実証できず GREEN が vacuous。flaky-FAIL を避けつつ
#                          「未証明」を明示する。→ 競合環境で再実行 or BDW_SELFTEST_N を上げる。
#   FAIL(exit 1)         : GREEN 不足 / READ 失敗 / LOCKDIR 不正 / GUARDBN 不一致
#
# 速度: embedded dolt の write は 1 件 ~1s。N=15・RED 数周 + GREEN 直列 + lock 保持テストで
#   数十秒かかる。

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
BDW="$HERE/bin/bdw"
N="${BDW_SELFTEST_N:-15}"                                  # 並列度
RED_ROUNDS="${BDW_SELFTEST_RED_ROUNDS:-3}"                 # RED 再現の試行周回
export BDW_LOCK_TIMEOUT="${BDW_LOCK_TIMEOUT:-180}"         # 遅い dolt でも timeout 誤検出しない

command -v bd >/dev/null 2>&1 || { echo "FAIL: bd not on PATH"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not on PATH"; exit 1; }
[ -x "$BDW" ] || { echo "FAIL: $BDW not found/executable"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/bdw-selftest-XXXXXX")"
HOLDER_PID=""        # READ-under-lock テストで lock を保持する背景プロセス
LOCK_FILE=""         # その throwaway repo 用 lock(bdw と同じ固定 lock dir 配下)
KEEP_MARKER=""       # これを消すと holder は自走終了(orphan sleep を残さない)
cleanup() {
  [ -n "${KEEP_MARKER:-}" ] && rm -f "$KEEP_MARKER"          # 先に holder を解放=自走終了させる
  [ -n "${HOLDER_PID:-}" ] && kill "$HOLDER_PID" 2>/dev/null # backstop
  [ -n "${HOLDER_PID:-}" ] && wait "$HOLDER_PID" 2>/dev/null
  [ -n "${LOCK_FILE:-}" ] && rm -f "$LOCK_FILE"
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}
trap cleanup EXIT

# ─── GUARDBN: 実行ファイルの basename が "bd" でないこと(guard 素通しの性質) ────────
# orchestrator の bd-write-guard は basename != "bd" のコマンドを無条件素通しする。canonical
# は "bdw" として呼ばれるため無改修で通る。basename を変えるとこの性質が壊れるので静的に検証。
guardbn_ok=false
if [ "$(basename "$BDW")" != "bd" ]; then guardbn_ok=true; fi
echo "  GUARDBN   : basename='$(basename "$BDW")' (guard 素通し条件 != bd) -> $([ "$guardbn_ok" = true ] && echo OK || echo FAIL)"

# ─── LOCKDIR: `bdw lock-dir` が lock_dir を stdout に出して exit 0 すること ───────────
# bd を呼ばない問い合わせ経路。既定(BDW_LOCK_DIR 未設定)で $HOME/.cache/bdw-locks を返すこと、
# および BDW_LOCK_DIR 明示時にそれを返すことの両方を確認する。
lockdir_ok=false
ld_default="$("$BDW" lock-dir 2>/dev/null)"; rc_def=$?
ld_override="$(BDW_LOCK_DIR=/tmp/bdw-selftest-override-dir "$BDW" lock-dir 2>/dev/null)"; rc_ovr=$?
if [ "$rc_def" -eq 0 ] && [ "$ld_default" = "$HOME/.cache/bdw-locks" ] \
   && [ "$rc_ovr" -eq 0 ] && [ "$ld_override" = "/tmp/bdw-selftest-override-dir" ]; then
  lockdir_ok=true
fi
echo "  LOCKDIR   : default='$ld_default' (rc=$rc_def) / override='$ld_override' (rc=$rc_ovr) -> $([ "$lockdir_ok" = true ] && echo OK || echo FAIL)"

# ─── throwaway な隔離 bd repo を構築 + 安全検証 ────────────────────────────────
(
  cd "$TMP" || exit 90
  git init -q || exit 90
  git config user.email selftest@example.com
  git config user.name bdw-selftest
  bd init >/dev/null 2>&1 || exit 90

  # SAFETY: bd が解決する repo root が temp 配下でなければ ABORT(実台帳保護)
  root="$(bd context 2>/dev/null | awk -F': *' '/repo root:/{print $2; exit}')"
  case "$root" in
    "$TMP"|"$TMP"/*) : ;;
    *) echo "ABORT: bd resolved repo root='$root' (expected under $TMP); refusing to write." >&2
       exit 91 ;;
  esac
) || { rc=$?; echo "FAIL: harness setup/safety check (rc=$rc)"; exit 1; }

# 1 ラウンド: N 並列で同一 issue へ append-notes → 生存した distinct note 数を echo
#   $1 = 実行ラッパ(bd の絶対委譲 / bdw)  $2 = ラベル
run_round() {
  local runner="$1" label="$2" tid i
  tid="$(cd "$TMP" && bd create --title "tgt-$label" --json 2>/dev/null | jq -r '.id')"
  if [ -z "$tid" ] || [ "$tid" = "null" ]; then echo "-1"; return; fi
  for i in $(seq 1 "$N"); do
    ( cd "$TMP" && "$runner" update "$tid" --append-notes "NL_${label}_${i}" >/dev/null 2>&1 ) &
  done
  wait
  (cd "$TMP" && bd show "$tid" 2>/dev/null) \
    | grep -oE "NL_${label}_[0-9]+" | sort -u | wc -l
}

echo "== bdw selftest: N=$N concurrent append-notes per round (throwaway DB: $TMP) =="

# ─── RED: bdw 無し。lost-update を再現(timing 依存ゆえ最大 RED_ROUNDS 周試行) ───
red_reproduced=false
red_last="-"
for r in $(seq 1 "$RED_ROUNDS"); do
  s="$(run_round bd "red${r}")"
  red_last="$s"
  echo "  RED  round${r}: survived ${s}/${N}  (raw bd, no serialization)"
  if [ "$s" -ge 0 ] && [ "$s" -lt "$N" ]; then red_reproduced=true; break; fi
done

# ─── GREEN: bdw 経由。直列化で全件残るはず(安全保証=hard 判定) ───
g="$(run_round "$BDW" green)"
echo "  GREEN     : survived ${g}/${N}  (via bdw flock)"

# ─── READ-under-lock: write-lock を別プロセスが保持中でも READ は即時素通しすること ───
# bdw が実際に使う lock_file を同一ロジックで算出(物理パス正規化込み)。算出が bdw とズレると
# 別ファイルを保持して誤判定するため、直後に WRITE が本当にブロックされるか(positive control)で
# 「保持した lock = bdw の lock」を担保する。
lk_common="$(cd "$TMP" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
[ -n "$lk_common" ] && lk_common="$(cd "$lk_common" 2>/dev/null && pwd -P || printf '%s' "$lk_common")"
lk_id="$(printf '%s' "${lk_common:-$TMP}" | sha256sum | cut -c1-16)"
# bdw と同じ解決ロジックを mirror する(ズレると別 lock を保持して positive control を誤判定。un-7nw)。
lk_dir="${BDW_LOCK_DIR:-$HOME/.cache/bdw-locks}"
mkdir -p "$lk_dir" 2>/dev/null || { echo "FAIL: cannot create lock dir $lk_dir" >&2; exit 1; }
LOCK_FILE="${lk_dir}/bd-write-${lk_id}.lock"

# WRITE positive control 用の probe issue(throwaway DB 内。timeout で打ち切るので副作用なし)
probe_tid="$(cd "$TMP" && bd create --title "probe-under-lock" --json 2>/dev/null | jq -r '.id')"

# lock を排他保持する背景プロセス: 取得したら ready marker を立て、keep marker が在る間だけ
# 短い sleep で保持を続ける。release は keep marker の削除で行い、holder は自走終了する
# (sleep 30 のような長寿命子プロセスを kill で孤児化させない=残骸ゼロ)。
ready_marker="$TMP/.holder-ready"
KEEP_MARKER="$TMP/.holder-keep"
: >"$KEEP_MARKER"
( flock -x 9 && : >"$ready_marker" && while [ -e "$KEEP_MARKER" ]; do sleep 0.2; done ) 9>"$LOCK_FILE" &
HOLDER_PID=$!
for _ in $(seq 1 50); do [ -e "$ready_marker" ] && break; sleep 0.1; done

write_blocked=false
read_ok=false
if [ -e "$ready_marker" ]; then
  # positive control: WRITE は lock を待つはず。bdw 自身の短い lock timeout(4s)で fail-closed
  # 終了させる(orphan flock を残さずクリーンに「ブロックした」を検出)。外側 timeout は backstop。
  # bdw は flock 取得前に諦めるので bd は走らず、台帳への副作用なし。
  if ( cd "$TMP" && BDW_LOCK_TIMEOUT=4 timeout 15 "$BDW" update "$probe_tid" --append-notes "blocked-probe" >/dev/null 2>&1 ); then
    write_blocked=false   # lock を取得して完走した=lock 配線がおかしい(保持中なのに書けた)
  else
    write_blocked=true    # 取得できず fail-closed=WRITE は確かに lock を待っている
  fi
  # READ は lock を待たず即時に返るはず(保持は継続中)
  t0=$EPOCHSECONDS
  if ( cd "$TMP" && timeout 10 "$BDW" list >/dev/null 2>&1 ); then
    [ $((EPOCHSECONDS - t0)) -lt 8 ] && read_ok=true
  fi
else
  echo "  WARN: lock holder が時間内に lock を取得できず READ-under-lock テストを実行不可" >&2
fi

# holder を停止: keep marker 削除で holder は ≤0.2s で自走終了する。kill せず wait で待つ
# (kill すると in-flight の sleep を孤児化するため。正常路では orphan を一切作らない)。
rm -f "$KEEP_MARKER"; KEEP_MARKER=""
wait "$HOLDER_PID" 2>/dev/null; HOLDER_PID=""
rm -f "$ready_marker"
echo "  WRITE-under-lock blocks : $([ "$write_blocked" = true ] && echo OK || echo FAIL)  (lock 配線の positive control)"
echo "  READ-under-lock passes  : $([ "$read_ok" = true ] && echo OK || echo FAIL)  (保持中でも即時素通し)"

# READ 次元は「保持中でも READ が即時素通し(read_ok)」かつ「同じ lock を WRITE は待つ
# (write_blocked=配線の positive control)」の両立で初めて証明される。
read_proven=false
[ "$read_ok" = true ] && [ "$write_blocked" = true ] && read_proven=true

echo "----------------------------------------------------------------------"
hard_fail=0
if [ "$g" -eq "$N" ]; then
  echo "ok  [GREEN]: bdw 経由で ${N}/${N} 全件保持(flock 直列化が機能)"
else
  echo "FAIL[GREEN]: bdw 経由で ${g}/${N} しか残らず lost-update(直列化が機能していない)"
  hard_fail=1
fi
if [ "$read_proven" = true ]; then
  echo "ok  [READ]:  write-lock 排他保持中でも READ は即時素通し(WRITE はブロック=配線も正)"
else
  echo "FAIL[READ]:  READ-under-lock 未証明(read_ok=$read_ok / write_blocked=$write_blocked)"
  hard_fail=1
fi
if [ "$lockdir_ok" = true ]; then
  echo "ok  [LOCKDIR]: bdw lock-dir が lock_dir を stdout に出して exit 0(consumer contract)"
else
  echo "FAIL[LOCKDIR]: bdw lock-dir の出力 or exit code が不正"
  hard_fail=1
fi
if [ "$guardbn_ok" = true ]; then
  echo "ok  [GUARDBN]: basename != bd(orchestrator bd-write-guard を無改修で素通し)"
else
  echo "FAIL[GUARDBN]: basename が bd(guard 素通しの前提が壊れている)"
  hard_fail=1
fi
if [ "$red_reproduced" = true ]; then
  echo "ok  [RED]:   bdw 無しで lost-update を再現(hazard 実在を確認=対比成立)"
else
  echo "n/a [RED]:   ${RED_ROUNDS} 周で lost-update を再現できず(timing。直近 survived=${red_last}/${N})"
fi

echo "----------------------------------------------------------------------"
# 3 値判定: GREEN/READ/LOCKDIR/GUARDBN は hard。RED→GREEN の対比が成立して初めて PASS。
if [ "$hard_fail" -ne 0 ]; then
  echo "RESULT: FAIL  (GREEN 不足 / READ 未証明 / LOCKDIR 不正 / GUARDBN 不一致)"
  exit 1
elif [ "$red_reproduced" = true ]; then
  echo "RESULT: PASS  (RED 再現 ∧ GREEN==N ∧ READ 素通し ∧ LOCKDIR ∧ GUARDBN = 全機能を明確に実証)"
  exit 0
else
  echo "RESULT: INCONCLUSIVE  (hard 次元は全 ok だが RED 非再現 = hazard 未実証ゆえ GREEN は vacuous)"
  echo "                       競合環境で再実行するか BDW_SELFTEST_N を上げて RED を再現させること"
  exit 2
fi
