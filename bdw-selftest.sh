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
#   LOCKFILE: `bdw lock-file` が「実際に掴む lock file 絶対パス」を stdout に出して exit 0。本テスト
#             自身がこの問い合わせを使って holder lock を算出する(lock 算出を mirror 再計算せず
#             bdw に問い合わせる=別 lock 誤掴みの drift を撲滅・un-7nw)。構造で検証: dir=lock-dir /
#             name=bd-write-<16hex>.lock。
#   GUARDBN : 実行ファイルの basename が "bd" でない(guard が basename!="bd" を素通しする性質)。
#   AUTOEXPORT: WRITE 成功後に .beads/issues.jsonl mirror を再生成(orch-89v 恒久 fix)。
#             (i) WRITE 後に mirror 再生成・対象 issue を含む / (ii) BDW_NO_AUTOEXPORT=1 で skip /
#             (iii) export 失敗を模擬しても WRITE の exit code=0 温存(fail-open) /
#             (iv) READ では auto-export が走らない /
#             (v) worktree→anchor 収束(A3): worktree 内からの WRITE でも mirror は anchor
#                 (git common-dir の親)の 1 つに収束し worktree 側 .beads/issues.jsonl は書かれない
#                 (show-toplevel 退行を落とす positive/negative の対比)。全て throwaway $TMP repo 内で実証。
#
# 最重要安全制約: 実 .beads 台帳を絶対に触らない。
#   本テストは mktemp の throwaway な git+bd repo だけを使い、書込前に `bd context` の
#   repo root が temp dir 配下であることを検証する。一致しなければ即 ABORT(書込まない)。
#
# 3 値判定(RED→GREEN の対比が成立して初めて PASS と言い切る):
#   PASS(exit 0)         : RED 再現(s<N) ∧ GREEN==N ∧ READ 素通し ∧ LOCKDIR ∧ LOCKFILE ∧ GUARDBN ∧ AUTOEXPORT ok
#   INCONCLUSIVE(exit 2) : hard 次元(GREEN/READ/LOCKDIR/LOCKFILE/GUARDBN/AUTOEXPORT)は全 ok だが RED 非再現
#                          (timing)= hazard を実証できず GREEN が vacuous。flaky-FAIL を避けつつ
#                          「未証明」を明示する。→ 競合環境で再実行 or BDW_SELFTEST_N を上げる。
#   FAIL(exit 1)         : GREEN 不足 / READ 失敗 / LOCKDIR 不正 / LOCKFILE 不正 / GUARDBN 不一致 / AUTOEXPORT 不正
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

# lock dir writability preflight(sandbox 対応): 既定 lock dir が書けない環境(OS sandbox の
# RO-bind 等)では throwaway repo の lock file を作れず全 WRITE が fail-closed になる。BDW_LOCK_DIR
# が未指定かつ既定 dir が書けない場合のみ、この harness 専用の書込可 temp lock dir へ退避する
# (LOCKDIR 次元の「真の既定値」検証は別途 `env -u BDW_LOCK_DIR` で行うため退避の影響を受けない)。
if [ -z "${BDW_LOCK_DIR:-}" ]; then
  _def_ld="${HOME:-/tmp}/.cache/bdw-locks"
  if ! ( mkdir -p "$_def_ld" 2>/dev/null && : >"$_def_ld/.bdw-selftest-wtest.$$" 2>/dev/null ); then
    export BDW_LOCK_DIR="$TMP/locks"
    echo "  (note) 既定 lock dir が書込不可 → harness 用 BDW_LOCK_DIR=$BDW_LOCK_DIR に退避(sandbox 対応)"
  else
    rm -f "$_def_ld/.bdw-selftest-wtest.$$" 2>/dev/null
  fi
fi
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
# 「真の既定値」は BDW_LOCK_DIR を明示的に外した clean env で検証する(harness が sandbox 退避で
# BDW_LOCK_DIR を設定していても、既定解決 $HOME/.cache/bdw-locks の検証意図を壊さない)。
ld_default="$(env -u BDW_LOCK_DIR "$BDW" lock-dir 2>/dev/null)"; rc_def=$?
ld_override="$(BDW_LOCK_DIR=/tmp/bdw-selftest-override-dir "$BDW" lock-dir 2>/dev/null)"; rc_ovr=$?
if [ "$rc_def" -eq 0 ] && [ "$ld_default" = "$HOME/.cache/bdw-locks" ] \
   && [ "$rc_ovr" -eq 0 ] && [ "$ld_override" = "/tmp/bdw-selftest-override-dir" ]; then
  lockdir_ok=true
fi
echo "  LOCKDIR   : default='$ld_default' (rc=$rc_def) / override='$ld_override' (rc=$rc_ovr) -> $([ "$lockdir_ok" = true ] && echo OK || echo FAIL)"

# ─── LOCKFILE: `bdw lock-file` が「実際に掴む lock file 絶対パス」を出して exit 0 すること ────
# bd を呼ばない問い合わせ経路。本テストはこの問い合わせで holder lock を算出する(下記 READ 節)
# = lock 算出を mirror 再計算せず bdw に一本化する根拠(別 lock 誤掴みの drift を撲滅・un-7nw)。
# 構造で検証する(算出を複製せず contract の形を突合): dir == lock-dir、name == bd-write-<16hex>.lock。
lockfile_ok=false
lf_out="$("$BDW" lock-file 2>/dev/null)"; rc_lf=$?
lf_dir_expected="$("$BDW" lock-dir 2>/dev/null)"
if [ "$rc_lf" -eq 0 ] && [ -n "$lf_out" ] \
   && [ "$(dirname "$lf_out")" = "$lf_dir_expected" ] \
   && printf '%s' "$(basename "$lf_out")" | grep -qE '^bd-write-[0-9a-f]{16}\.lock$'; then
  lockfile_ok=true
fi
echo "  LOCKFILE  : lock-file='$lf_out' (rc=$rc_lf) -> $([ "$lockfile_ok" = true ] && echo OK || echo FAIL)"

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
# bdw が実際に掴む lock_file を bdw 自身に問い合わせて取得する(算出を mirror 再計算しない=un-7nw)。
# 算出を selftest 側で複製すると bdw とズレ、別 lock を保持して positive control を誤判定しうる——
# lock-file subcommand の新設でその窓を構造的に塞ぐ。万一問い合わせ結果が bdw の実掴みとズレても、
# 直後に WRITE が本当にブロックされるか(positive control)で「保持した lock = bdw の lock」を担保する。
LOCK_FILE="$(cd "$TMP" && "$BDW" lock-file 2>/dev/null)"
[ -n "$LOCK_FILE" ] || { echo "FAIL: bdw lock-file が空を返した(lock 算出の問い合わせに失敗)" >&2; exit 1; }
mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || { echo "FAIL: cannot create lock dir for $LOCK_FILE" >&2; exit 1; }

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

# ─── AUTOEXPORT: WRITE 成功後の .beads/issues.jsonl mirror 再生成(orch-89v 恒久 fix) ───
# throwaway $TMP repo(git common-dir の親 = $TMP・.beads 実在)を使い 5 命題を実証する:
#   (i)   WRITE(update)後に $TMP/.beads/issues.jsonl が再生成され、対象 issue を含む
#   (ii)  BDW_NO_AUTOEXPORT=1 では auto-export が skip される(mirror が再生成されない)
#   (iii) export 失敗を模擬(issues.jsonl を dir 化=書込不能)しても WRITE の exit code=0 温存(fail-open)
#   (iv)  READ(list)では auto-export が走らない(mirror 再生成されない)
#   (v)   worktree→anchor 収束(A3 の load-bearing 差別化): $TMP に git worktree を張り、worktree 内から
#         WRITE すると mirror は anchor($TMP)の .beads/issues.jsonl に収束し、worktree 側の
#         .beads/issues.jsonl は書かれない。worktree の .beads は tracked ファイルのみ(embeddeddolt
#         不在=物理 DB は anchor 一元)だが .beads dir 自体は checkout で実在するため、resolve_export_root
#         が show-toplevel へ退行すると『.beads 実在』条件を満たして worktree 側へ stale mirror を書く——
#         その退行を負側 assert(worktree mirror 不在)で検出する(plain repo では両実装が同結果で検出不能)。
JSONL="$TMP/.beads/issues.jsonl"
ae_tid="$(cd "$TMP" && bd create --title "autoexport-target" --json 2>/dev/null | jq -r '.id')"

# (i) WRITE で mirror が再生成され、対象 issue を含む
ae_i_ok=false
rm -f "$JSONL"
( cd "$TMP" && "$BDW" update "$ae_tid" --append-notes "AE_i" >/dev/null 2>&1 )
if [ -n "$ae_tid" ] && [ -s "$JSONL" ] && grep -q "$ae_tid" "$JSONL" 2>/dev/null; then ae_i_ok=true; fi

# (ii) BDW_NO_AUTOEXPORT=1 で skip(escape hatch)
ae_ii_ok=false
rm -f "$JSONL"
( cd "$TMP" && BDW_NO_AUTOEXPORT=1 "$BDW" update "$ae_tid" --append-notes "AE_ii" >/dev/null 2>&1 )
[ ! -e "$JSONL" ] && ae_ii_ok=true

# (iii) export 失敗を模擬(issues.jsonl を dir 化 → -o が書けず export 失敗)しても WRITE rc=0 温存
ae_iii_ok=false
rm -f "$JSONL"; mkdir -p "$JSONL"
if ( cd "$TMP" && "$BDW" update "$ae_tid" --append-notes "AE_iii" >/dev/null 2>&1 ); then
  ae_iii_ok=true   # WRITE は成功(rc=0)= fail-open で mirror 失敗を write に波及させない
fi
rmdir "$JSONL" 2>/dev/null || rm -rf "$JSONL"

# (iv) READ(list)では auto-export が走らない(素通しパスは lock も export も取らない)
ae_iv_ok=false
rm -f "$JSONL"
( cd "$TMP" && "$BDW" list >/dev/null 2>&1 )
[ ! -e "$JSONL" ] && ae_iv_ok=true

# (v) worktree→anchor 収束: $TMP に worktree を張り、その中から WRITE。mirror は anchor($TMP)へ
#     収束し(正側 assert)、worktree 側 .beads/issues.jsonl は書かれない(負側 assert=show-toplevel 退行検出)。
ae_v_ok=false
WT="$TMP/.worktrees/wt"
if ( cd "$TMP" && git worktree add -q "$WT" -b bdw-selftest-wt >/dev/null 2>&1 ); then
  wt_jsonl="$WT/.beads/issues.jsonl"
  rm -f "$JSONL" "$wt_jsonl"
  ( cd "$WT" && "$BDW" update "$ae_tid" --append-notes "AE_v_wt" >/dev/null 2>&1 )
  # 正側: anchor($TMP)の mirror が再生成され対象 issue を含む / 負側: worktree 側 mirror は不在
  if [ -s "$JSONL" ] && grep -q "$ae_tid" "$JSONL" 2>/dev/null && [ ! -e "$wt_jsonl" ]; then
    ae_v_ok=true
  fi
fi

autoexport_ok=false
[ "$ae_i_ok" = true ] && [ "$ae_ii_ok" = true ] && [ "$ae_iii_ok" = true ] && [ "$ae_iv_ok" = true ] && [ "$ae_v_ok" = true ] && autoexport_ok=true
echo "  AUTOEXPORT: (i)regen=$ae_i_ok (ii)skip=$ae_ii_ok (iii)failopen-rc0=$ae_iii_ok (iv)read-noexport=$ae_iv_ok (v)wt->anchor=$ae_v_ok -> $([ "$autoexport_ok" = true ] && echo OK || echo FAIL)"

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
if [ "$lockfile_ok" = true ]; then
  echo "ok  [LOCKFILE]: bdw lock-file が lock file 絶対パスを stdout に出して exit 0(consumer contract)"
else
  echo "FAIL[LOCKFILE]: bdw lock-file の出力 or exit code が不正"
  hard_fail=1
fi
if [ "$guardbn_ok" = true ]; then
  echo "ok  [GUARDBN]: basename != bd(orchestrator bd-write-guard を無改修で素通し)"
else
  echo "FAIL[GUARDBN]: basename が bd(guard 素通しの前提が壊れている)"
  hard_fail=1
fi
if [ "$autoexport_ok" = true ]; then
  echo "ok  [AUTOEXPORT]: WRITE 後に mirror 再生成 / NO_AUTOEXPORT=1 skip / fail-open rc=0 / READ 無 export"
else
  echo "FAIL[AUTOEXPORT]: (i)regen=$ae_i_ok (ii)skip=$ae_ii_ok (iii)failopen-rc0=$ae_iii_ok (iv)read-noexport=$ae_iv_ok (v)wt->anchor=$ae_v_ok"
  hard_fail=1
fi
if [ "$red_reproduced" = true ]; then
  echo "ok  [RED]:   bdw 無しで lost-update を再現(hazard 実在を確認=対比成立)"
else
  echo "n/a [RED]:   ${RED_ROUNDS} 周で lost-update を再現できず(timing。直近 survived=${red_last}/${N})"
fi

echo "----------------------------------------------------------------------"
# 3 値判定: GREEN/READ/LOCKDIR/LOCKFILE/GUARDBN/AUTOEXPORT は hard。RED→GREEN の対比が成立して初めて PASS。
if [ "$hard_fail" -ne 0 ]; then
  echo "RESULT: FAIL  (GREEN 不足 / READ 未証明 / LOCKDIR 不正 / LOCKFILE 不正 / GUARDBN 不一致 / AUTOEXPORT 不正)"
  exit 1
elif [ "$red_reproduced" = true ]; then
  echo "RESULT: PASS  (RED 再現 ∧ GREEN==N ∧ READ 素通し ∧ LOCKDIR ∧ LOCKFILE ∧ GUARDBN ∧ AUTOEXPORT = 全機能を明確に実証)"
  exit 0
else
  echo "RESULT: INCONCLUSIVE  (hard 次元は全 ok だが RED 非再現 = hazard 未実証ゆえ GREEN は vacuous)"
  echo "                       競合環境で再実行するか BDW_SELFTEST_N を上げて RED を再現させること"
  exit 2
fi
