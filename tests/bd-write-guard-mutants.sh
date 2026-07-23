#!/usr/bin/env bash
# tests/bd-write-guard-mutants.sh — universal guard の不変条件↔検証の非空虚性を named mutant で実証(un-37xq)。
#
# 各 named mutant を guard の copy に適用し、`python3 <mutated-guard> --self-test`(token 50 + 動的 prefix +
# fail 2 段 の 3 battery)が **FAIL(exit!=0)** することを確認する。全 mutant が期待どおり差分を出せば exit 0
# (検証は非空虚)。1 つでも mutant が --self-test を pass させれば当該不変条件の検証は vacuous → exit 1。
#
# 不変条件 ↔ mutant ↔ 破れる battery:
#   ① 自台帳のみ(rule b)     : M-rule-b   _foreign_beads を空に      : token(non-self→b)
#   逸脱(1)動的 prefix        : M-static   ident→定数"sc"移植          : dynamic-prefix
#   逸脱(2)dolt funnel        : M-dolt     DOLT_FUNNEL を空に          : token(dolt push→c)
#   逸脱(3)fail-closed(識別子) : M-f2-open  identity-unreadable→fail-open: fail2(① 2→0)
#   逸脱(3)fail-open(remote)   : M-f2-closed remote-UNKNOWN の fail-open 無効化: fail2(② 0→2)

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
GUARD="$ROOT/scripts/hooks/bd-write-guard.py"
LIB="$ROOT/scripts/hooks/lib/bdw_session.py"
export CMDTOKENS_LIB="${CMDTOKENS_LIB:-$HOME/.claude/plugins/cmdtokens/lib}"
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 absent (core tool・skip 禁止)"; exit 1; }
[ -f "$CMDTOKENS_LIB/cmdtokens.py" ] || { echo "FAIL: cmdtokens lib 不在: $CMDTOKENS_LIB"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bdguard-mut-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
LOG="${BDGUARD_MUTANT_LOG:-$WORK/mutant-differential.log}"; : > "$LOG"
fails=0

# run_mutant <name> <search> <replace> <invariant-label>
run_mutant() {
  local name="$1" search="$2" replace="$3" label="$4"
  local md="$WORK/$name"; mkdir -p "$md/scripts/hooks/lib"
  cp "$GUARD" "$md/scripts/hooks/bd-write-guard.py"
  cp "$LIB" "$md/scripts/hooks/lib/bdw_session.py"
  local mg="$md/scripts/hooks/bd-write-guard.py"
  # python で一意 str.replace(適用回数を確認=0 件は harness bug)。
  local n
  n="$(SEARCH="$search" REPLACE="$replace" MG="$mg" python3 - <<'PY'
import os
p=os.environ["MG"]; s=os.environ["SEARCH"]; r=os.environ["REPLACE"]
src=open(p,encoding="utf-8").read()
cnt=src.count(s)
if cnt>0:
    open(p,"w",encoding="utf-8").write(src.replace(s,r))
print(cnt)
PY
)"
  if [ "$n" -lt 1 ]; then
    echo "  [$name] search 文字列が 0 件マッチ(harness bug)" | tee -a "$LOG"; fails=$((fails+1)); return
  fi
  if ! python3 -c "import ast; ast.parse(open('$mg',encoding='utf-8').read())" 2>/dev/null; then
    echo "  [$name] MUTANT が構文破壊(無効 mutant)" | tee -a "$LOG"; fails=$((fails+1)); return
  fi
  local out rc
  out="$(python3 "$mg" --self-test 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    { echo "MUTANT-DIFF ok  [$name/$label] mutant 適用で --self-test が FAIL(=検証は非空虚)"
      printf '%s\n' "$out" | grep -E '^(FAIL|bd-guard).*(FAIL|ABORT)' | head -3 | sed 's/^/    /'
    } | tee -a "$LOG"
  else
    echo "MUTANT-DIFF FAIL[$name/$label] mutant 適用でも --self-test が pass(=vacuous!)" | tee -a "$LOG"
    fails=$((fails+1))
  fi
}

echo "== universal bd-write-guard mutant differential ==" | tee -a "$LOG"

# M-rule-b: _foreign_beads を常に空に → rule b(非 self bead deny)が発火しなくなる。
run_mutant M-rule-b \
  'return [t for t in ids if BD_ID_RE.match(t) and not t.startswith(self_id_pfx)]' \
  'return []  # MUTANT' "①self-only(rule b)"

# M-collision: separator 境界を外し raw self_pfx で startswith 判定 → prefix-collision で foreign が
#   self 扱いへ落ち rule b が弱化(owner-2 moat バイパス)。collision pin(scr-1/sc2-1)が RED 化する。
run_mutant M-collision \
  'not t.startswith(self_id_pfx)]' \
  'not t.startswith(self_pfx)]  # MUTANT' "①self-only 境界(prefix-collision)"

# M-static: 動的解決 ident を定数 "sc" へ(定数移植 mutant)→ un session の判定が反転。
run_mutant M-static \
  'return decide(cmd, cwd, ident)' \
  'return decide(cmd, cwd, "sc")  # MUTANT' "逸脱(1)動的prefix"

# M-dolt: DOLT_FUNNEL を空に → self dolt push/pull が allow へ戻る(J2 bare-allow 復活)。
run_mutant M-dolt \
  'DOLT_FUNNEL = {"push", "pull"}' \
  'DOLT_FUNNEL = set()  # MUTANT' "逸脱(2)dolt funnel"

# M-f2-open: identity-unreadable の fail-closed を fail-open へ → ① が 2→0 に反転。
run_mutant M-f2-open \
  'return decide(cmd, cwd, _IMPOSSIBLE_PFX)' \
  'return (0, "")  # MUTANT' "逸脱(3)fail-closed(識別子)"

# M-f2-closed: remote-UNKNOWN の fail-open を無効化 → 落ちて enforce され ② が 0→2 に反転。
run_mutant M-f2-closed \
  'if remote is _REMOTE_UNKNOWN:' \
  'if False and remote is _REMOTE_UNKNOWN:  # MUTANT' "逸脱(3)fail-open(remote)"

# M-append: SUBCMD_VAL_FLAGS から "--append-notes" を除去 → 値 gate-pending が positional 扱いになり
#   self 更新が (c)→(b) へ反転(un-a0t9 の FP 再現)。値取り flag 登録が load-bearing である証明。
run_mutant M-append \
  '"--add-label", "--append-notes", "--await-id", "--body-file", "--defer",' \
  '"--add-label", "--await-id", "--body-file", "--defer",  # MUTANT' "un-a0t9 値取り flag 網羅"

# M-boolmoat: SUBCMD_VAL_FLAGS へ bool の "--claim" を注入 → 直後の foreign positional un-9 が値として
#   食われ rule(b) が沈黙し (b)→(c) へ反転。moat pin(fail-closed→fail-open 反転検知)の非空虚性証明。
run_mutant M-boolmoat \
  '"--timeout", "--holder", "--coordinator",' \
  '"--timeout", "--holder", "--coordinator", "--claim",  # MUTANT' "un-a0t9 fail-open 禁止(bool 混入)"

# M-arity: subcmd 別 bool override を無効化 → edit/gate/mol の bool flag 直後の foreign が値として
#   食われ (b)→(c) へ反転。arity 明示形(flat 集合では表現不能)の non-vacuity 証明。
run_mutant M-arity \
  'return SUBCMD_VAL_FLAGS - override if override else SUBCMD_VAL_FLAGS' \
  'return SUBCMD_VAL_FLAGS  # MUTANT' "un-a0t9 subcmd 別 arity"

# M-alias: subcmd alias 正規化を無効化 → `bd protomolecule show -p un-9` で override が外れ -p が
#   foreign un-9 を値として食い (b)→(c) へ反転。alias 経路の fail-open 封鎖が load-bearing である証明。
run_mutant M-alias \
  'sub = SUBCMD_ALIASES.get(sub, sub)  # alias 経路で override が外れる fail-open を封鎖' \
  'pass  # MUTANT' "un-a0t9 subcmd alias 正規化"

# M-fromfile: rule(d) 汎化分岐を除去 → 対象 id を別ファイルに持つ write(delete --from-file /
#   dep add --file / migrate issues --ids-file)が funnel(c) で素通り(fail-open)。分岐が load-bearing。
run_mutant M-fromfile \
  'if _external_id_source_flag(sub, operands) is not None:' \
  'if False:  # MUTANT' "un-a0t9 外部 id ソース write の rule(d)"

# M-extsibling: 汎化テーブルから兄弟経路(dep add --file)のみを除去 → delete は閉じたまま
#   `bd dep add --file deps.jsonl` が (c) へ落ちる。delete 決め打ちに戻す退行の検知が非空虚である証明。
run_mutant M-extsibling \
  '"dep": {"--file"},' \
  '# MUTANT' "un-a0t9 rule(d) 汎化(兄弟経路)"

# M-idval: 値が bead id 自体になる flag(--of)を SUBCMD_VAL_FLAGS へ注入 → 値 un-9 が消費され foreign
#   検査面から消えて (b)→(c) へ反転。id 値 flag 非登録=fail-closed pin の非空虚性証明。
run_mutant M-idval \
  '"--timeout", "--holder", "--coordinator",' \
  '"--timeout", "--holder", "--coordinator", "--of", "--event-target", "--waits-for",  # MUTANT' \
  "un-a0t9 id 値 flag 非登録(fail-closed)"

# M-molfp: mol の create-like 免除集合を空に → mol pour/wisp の positional proto-id が foreign 誤検出へ
#   戻り FP pin(mol pour mol-feat→c)が RED 化。免除分岐が load-bearing である証明(un-aukl)。
run_mutant M-molfp \
  'MOL_CREATE_LIKE = {"pour", "wisp"}' \
  'MOL_CREATE_LIKE = set()  # MUTANT' "un-aukl mol create-like 免除(FP 解消)"

# M-molmoat: 免除を burn へ拡張 → 既存 mol への write(mol burn un-9)が (b)→(c) へ反転し moat pin が
#   RED 化。{pour,wisp} 厳密限定(拡張禁止=fail-open 封鎖)の非空虚性証明(un-aukl)。
run_mutant M-molmoat \
  'MOL_CREATE_LIKE = {"pour", "wisp"}' \
  'MOL_CREATE_LIKE = {"pour", "wisp", "burn"}  # MUTANT' "un-aukl mol 免除の厳密限定(moat)"

# M-help: -h/--help 短絡を除去 → bd update --help 等が rule(c) deny へ戻り FP pin(allow=0)が RED 化。
#   has_help 短絡が load-bearing である証明(un-aukl item(3))。
run_mutant M-help \
  'if has_help or _has_help_operand(operands, sub):' \
  'if False:  # MUTANT' "un-aukl write-subcmd+--help 短絡 allow"

# M-helpval: _has_help_operand の未登録 flag fail-closed 分岐を「読み飛ばし継続」へ緩和 → --of/--attach/
#   --waits-for 等の値位置 --help が help 誤判定され deny(b/a/c)→allow へ反転(fail-open)。self-review
#   moat pin(bd duplicate un-9 --of --help→b 等)が RED 化。fail-closed 分岐が load-bearing である証明。
run_mutant M-helpval \
  'return False  # ★un-aukl fail-closed: 未登録 flag は arity 不明 → help 扱いしない' \
  'i += 1; continue  # MUTANT' "un-aukl 値位置 --help の fail-closed(未登録 flag)"

echo "----" | tee -a "$LOG"
if [ "$fails" -eq 0 ]; then
  echo "GUARD MUTANT DIFFERENTIAL: PASS(全 mutant が --self-test を FAIL させた=検証は非空虚)" | tee -a "$LOG"
  echo "log: $LOG"; exit 0
else
  echo "GUARD MUTANT DIFFERENTIAL: FAIL($fails 件)" | tee -a "$LOG"
  echo "log: $LOG"; exit 1
fi
