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

echo "----" | tee -a "$LOG"
if [ "$fails" -eq 0 ]; then
  echo "GUARD MUTANT DIFFERENTIAL: PASS(全 mutant が --self-test を FAIL させた=検証は非空虚)" | tee -a "$LOG"
  echo "log: $LOG"; exit 0
else
  echo "GUARD MUTANT DIFFERENTIAL: FAIL($fails 件)" | tee -a "$LOG"
  echo "log: $LOG"; exit 1
fi
