#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# PreToolUse(Bash) hook: bd の bare write を「自台帳のみ・bdw funnel」へ機械強制する universal guard(exit 2)。
#
# PROVENANCE ───────────────────────────────────────────────────────────────────
# un-37xq(universal funnel guard の full-port)Leg-B。移植元 = scribe/scriptorium の
#   bd-write-guard.py(session-scoped・SELF_PREFIX 定数)。本 guard は beads-bdw plugin に同梱し
#   PreToolUse[Bash] で全セッション発火する **universal** 版。契約 SSOT = scriptorium orch-klca /
#   bd un-10h5 notes「dispatch 前 mandate-verify #2」fence。
#
# ★意図的逸脱(忠実 port 禁止・必須 echo back・un-37xq 契約) ────────────────────────────────
#   (1) SELF_PREFIX を **定数移植しない**。cwd の `.beads/metadata.json` dolt_database を **実行時解決**し
#       rule (a)(b)(c) 全てに使う(bdw_session.resolve_self_prefix)。全13台帳で false-BLOCK しない。
#   (2) self bare `bd dolt push`/`bd dolt pull` は移植元 J2 の bare-allow でなく **kind 'c'(bdw funnel)**
#       へ落とす(flock 迂回 race 封鎖・invariant③)。foreign(-C/--db/--global) dolt push deny(kind a)は不変。
#   (3) fail 2 段(逆極性): 台帳 identity(metadata dolt_database)present-but-unreadable → **fail-closed**
#       (bare write deny・moat 維持) / has-remote 判定不能(config.yaml read 不能) → **fail-open+loud**
#       (local-only project を universal blast radius で brick しない・人間承認済み逸脱)。
#   (4) has-remote gate: remote 未設定(local-only)台帳では guard を **no-op**(coordination 不要ゆえ)。
#       universal 発火だが remote-backed 台帳にのみ funnel を効かせる。
#   (5) funnel message は repo 相対 `scripts/bdw` を含めず **canonical bdw 案内へ generic 化**。
#
# 方式(移植元と同一): コマンド文字列を cmdtokens.iter_commands で shlex トークン化し **本物の `bd` 呼出し
#   のトークン列にのみ**ルールを適用する(echo/クォート内/コメント/launcher 経由の誤検出を構造排除)。
#   直列化ラッパ `bdw`(basename != "bd")は guard 対象外=bdw 経由 write はそのまま通過する。
#
# guard rule(3 本柱・動的 self_prefix 基準):
#   (a) -C/--directory/--db/--global を伴う write は deny(foreign 台帳 write=owner 2人違反)。read は対象外。
#   (b) global flag 無しでも対象 bead が **非 self-prefix** なら deny(hydrated foreign copy の mutate 防止)。
#   (c) 上記を通過した自台帳(self-prefix)への bare bd write は block し bdw 経由へ差し戻す(lost-update 防止)。
#   funnel 対象に self `bd dolt push/pull` を含める(逸脱(2))。
#
# 失敗時方針: 入力解析・guard 内部・lib ロードのいずれの例外でも **fail-open(exit 0)**=全 Bash を brick しない
#   (hooks.json の二重 fail-safe 指示に従う)。ただし fail 2 段(3)の identity-unreadable のみ意図的に fail-closed。
# 検証: `python3 bd-write-guard.py --self-test`(token 判定 battery + 動的 prefix battery + fail-2段 battery)。

import sys
import os
import re
import json

# --- cmdtokens consume preamble(logic ゼロの薄い解決層・移植元と同形) --------------------------
# canonical cmdtokens(standalone plugin の単一 SSOT)を sys.path 解決して import するだけ。
# CMDTOKENS_LIB(env)未設定/空/非絶対は plugin 標準配置へ fallback。取り込む API は iter_commands のみ。
_CMDTOKENS_DEFAULT_LIB = os.path.expanduser("~/.claude/plugins/cmdtokens/lib")
_cmdtokens_lib = os.path.expanduser(os.environ.get("CMDTOKENS_LIB") or _CMDTOKENS_DEFAULT_LIB)
if not os.path.isabs(_cmdtokens_lib):
    _cmdtokens_lib = _CMDTOKENS_DEFAULT_LIB
_cmdtokens_load_error = None
try:
    sys.path.insert(0, _cmdtokens_lib)
    from cmdtokens import iter_commands
except Exception as e:  # lib ロード不能 → fail-open(guard 無効化を loud に通知)
    iter_commands = None
    _cmdtokens_load_error = e
    if "--self-test" not in sys.argv and "--print-cmdtokens-lib" not in sys.argv:
        sys.stderr.write(f"[bd-guard] cannot load cmdtokens lib, failing open: {e}\n")
        sys.exit(0)

# --- 動的 self-prefix + has-remote lib(同梱 lib/・logic ゼロの薄い解決層) --------------------
_session_load_error = None
try:
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.realpath(__file__)), "lib"))
    from bdw_session import (
        walk_up_beads, resolve_self_prefix, has_remote,
        _LEDGER_UNREADABLE, _REMOTE_YES, _REMOTE_NO, _REMOTE_UNKNOWN,
    )
except Exception as e:  # 同梱 lib ロード不能 → fail-open
    _session_load_error = e
    _LEDGER_UNREADABLE = object()
    _REMOTE_YES = _REMOTE_NO = _REMOTE_UNKNOWN = object()

    def walk_up_beads(cwd):
        return None

    def resolve_self_prefix(b):
        return None

    def has_remote(b):
        return _REMOTE_NO
    if "--self-test" not in sys.argv and "--print-cmdtokens-lib" not in sys.argv:
        sys.stderr.write(f"[bd-guard] cannot load bdw_session lib, failing open: {e}\n")
        sys.exit(0)

# bd の id トークン形(<prefix>-<suffix>)。
BD_ID_RE = re.compile(r"^[a-z][a-z0-9]*-[0-9a-z]+$")

# fail-closed(identity unreadable)時に使う「どの bead にも一致しない」sentinel prefix。
# これを self_pfx に渡すと全 bead が foreign(b)/create(c)へ落ち全 write が block(exit2)=moat 維持。
_IMPOSSIBLE_PFX = "\x00\x00-"

# グローバル値フラグは _parse_bd 内で個別に消費する(-C/--directory/--db/--actor/--dolt-auto-commit・
# glued/= 形も含む)。集合定数は持たない(移植元の未使用残骸を撤去=SSOT は _parse_bd 単体)。
GLOBAL_BOOL_FLAGS = {"--global", "--readonly", "--json", "-q", "--quiet", "--profile", "-h", "--help"}

READ_SUBCMDS = {
    "show", "list", "ready", "blocked", "search", "query", "count", "children",
    "comments", "history", "diff", "find-duplicates", "duplicates",
    "lint", "stale", "status", "statuses", "types", "graph", "export",
    "context", "info", "where", "memories", "recall", "prime", "quickstart",
    "human", "version", "help", "completion", "ping", "preflight", "orphans",
    "state", "onboard", "find", "blocked-by", "init-safety",
}
DEP_READ = {"list", "tree", "cycles"}
REPO_READ = {"list"}
HIGH_DANGER_WRITE = {"sql", "batch", "import"}
CREATE_LIKE = {"create", "q", "create-form"}
# self dolt funnel 対象(逸脱(2)): push/pull は flock 迂回 race を封鎖するため bdw funnel(c)。
DOLT_FUNNEL = {"push", "pull"}

SUBCMD_VAL_FLAGS = {
    "--status", "-s", "--reason", "-r", "--priority", "-p", "--notes", "-n",
    "--assignee", "-a", "--owner", "--title", "-t", "--type", "--design",
    "--acceptance", "--message", "-m", "--with", "--label", "-l", "--milestone",
    "--parent", "--estimate", "--actor", "--limit", "--format", "--sort",
    "--from", "--to", "--depends-on", "--blocked-by", "--description", "-d",
}


def _pfx(self_pfx):
    """self_pfx から `<pfx>-` を作る(表示/判定用)。"""
    return self_pfx + "-"


def msg_a(self_pfx):
    return ("foreign 台帳(-C/--directory/--db/--global)への bd write は禁止(owner 2人違反)。write してよいのは "
            "自台帳(prefix '" + _pfx(self_pfx) + "')のみ。foreign bead は read 専用(bd --readonly / bd show|list ...)。")


def msg_b(self_pfx, fb):
    return ("非 '" + _pfx(self_pfx) + "' prefix bead への bd write は禁止。hydrate された foreign bead は自 DB 内の "
            "copy で mutate すると source と乖離する。foreign は read 専用、write は自台帳 issue にのみ。対象: " + fb)


def msg_c(self_pfx):
    return ("自台帳('" + _pfx(self_pfx) + "')への bd write は直列化ラッパ bdw 経由で実行せよ。embedded Dolt は "
            "single-writer で bare bd write を並行すると lost-update が起きる(bdw が flock で直列化)。"
            "canonical bdw(beads-bdw plugin)を consume する自 repo の bdw を使え。")


def msg_d(self_pfx):
    return ("bd sql(非SELECT) / batch / import は id を引数で取らず対象 bead を SQL 文字列・別ファイル・stdin に "
            "持つため foreign 台帳を機械検査できず owner 2人違反を取りこぼす。これら高危険 write は禁止。read は "
            "`bd sql` の SELECT を `bd --readonly` 経由、write は id 明示形(自台帳 '" + _pfx(self_pfx) + "' bead)を bdw 経由で。")


def _parse_bd(args):
    """bd のグローバルフラグを消費し (sub, operands, foreign, has_readonly) を返す(移植元と同一)。"""
    has_C = has_db = has_global = has_readonly = False
    sub = None
    operands = []
    i, n = 0, len(args)
    while i < n:
        t = args[i]
        if t in ("-C", "--directory"):
            has_C = True; i += 2; continue
        if t == "--db":
            has_db = True; i += 2; continue
        if t in ("--actor", "--dolt-auto-commit"):
            i += 2; continue
        if t.startswith("--directory=") or (t.startswith("-C") and len(t) > 2):
            has_C = True; i += 1; continue
        if t.startswith("--db="):
            has_db = True; i += 1; continue
        if t.startswith("--actor=") or t.startswith("--dolt-auto-commit="):
            i += 1; continue
        if t == "--global":
            has_global = True; i += 1; continue
        if t == "--readonly":
            has_readonly = True; i += 1; continue
        if t in GLOBAL_BOOL_FLAGS:
            i += 1; continue
        if t.startswith("-"):
            if sub is None:
                i += 1
            else:
                operands.append(t); i += 1
            continue
        if sub is None:
            sub = t
        else:
            operands.append(t)
        i += 1
    return sub, operands, (has_C or has_db or has_global), has_readonly


def _positional_operands(operands):
    """operands 全体から positional token を順序保持で抽出(interspersed flag 貫通・移植元と同一)。"""
    out = []
    i, n = 0, len(operands)
    while i < n:
        a = operands[i]
        if a.startswith("-"):
            if a in SUBCMD_VAL_FLAGS and "=" not in a:
                i += 2
            else:
                i += 1
            continue
        out.append(a)
        i += 1
    return out


def _blocks_value(operands):
    for i, a in enumerate(operands):
        if a in ("--blocks", "-b"):
            return operands[i + 1] if i + 1 < len(operands) else None
        if a.startswith("--blocks="):
            return a.split("=", 1)[1]
        if a.startswith("-b") and len(a) > 2 and not a.startswith("-b="):
            return a[2:]
        if a.startswith("-b="):
            return a.split("=", 1)[1]
    return None


def _foreign_beads(ids, self_pfx):
    """id 群のうち bd-id 形かつ非 self-prefix のもの(動的 self_pfx 基準)。

    ★境界: `_pfx(self_pfx)`(= '<pfx>-')で startswith 判定する。raw `self_pfx`(dash 無し)
    で判定すると prefix-collision(例 self='sc' に対し foreign 'scr-1'、self='un' に対し 'und-5')
    が startswith True で self 扱いへ落ち、rule(b) deny を funnel(c)へ誤誘導=owner-2 moat のバイパス。
    表示用 msg_a/b/c が self_pfx+'-' を組むのと対称に、separator 境界を強制する。"""
    self_id_pfx = _pfx(self_pfx)
    return [t for t in ids if BD_ID_RE.match(t) and not t.startswith(self_id_pfx)]


def _check_dep(operands, foreign, self_pfx, is_link=False):
    pos = _positional_operands(operands)
    if is_link:
        pos = ["add"] + pos
    action = pos[0] if pos else None
    if not is_link and action in DEP_READ:
        return None
    if foreign:
        return ("a", msg_a(self_pfx))
    blocks_val = None if is_link else _blocks_value(operands)
    if action in ("add", "remove"):
        targets = pos[1:2]
    elif action in ("relate", "unrelate"):
        targets = pos[1:]
    elif blocks_val is not None:
        targets = [blocks_val]
    else:
        targets = [a for a in pos if BD_ID_RE.match(a)]
    fb = _foreign_beads(targets, self_pfx)
    if fb:
        return ("b", msg_b(self_pfx, " ".join(fb)))
    return ("c", msg_c(self_pfx))


def _check_repo(operands, foreign, self_pfx):
    pos = _positional_operands(operands)
    action = pos[0] if pos else None
    if action is None or action in REPO_READ:
        return None
    if foreign:
        return ("a", msg_a(self_pfx))
    return ("c", msg_c(self_pfx))


def check_bd(core, self_pfx):
    """bd コマンドの token 列を判定。(kind, reason) or None(allow)。self_pfx は動的解決値。"""
    sub, operands, foreign, has_readonly = _parse_bd(core[1:])
    if sub is None:
        return None
    if has_readonly:
        return None
    if sub in READ_SUBCMDS:
        return None

    if sub == "dolt":
        # J2 + ★逸脱(2): foreign→deny(a) / self push|pull→bdw funnel(c) / 他 dolt(commit/status/…)→allow。
        if foreign:
            return ("a", msg_a(self_pfx))
        pos = _positional_operands(operands)
        action = pos[0] if pos else None
        if action in DOLT_FUNNEL:
            return ("c", msg_c(self_pfx))  # ★flock 迂回 race 封鎖: self dolt push/pull も bdw funnel
        return None  # dolt commit/status/start/stop 等は同期点/read = allow

    if sub == "dep":
        return _check_dep(operands, foreign, self_pfx)
    if sub == "link":
        return _check_dep(operands, foreign, self_pfx, is_link=True)
    if sub == "repo":
        return _check_repo(operands, foreign, self_pfx)
    if sub in HIGH_DANGER_WRITE:
        return ("a", msg_d(self_pfx))  # J6: id 不明高危険 write は一律 deny

    if foreign:
        return ("a", msg_a(self_pfx))
    if sub in CREATE_LIKE:
        return ("c", msg_c(self_pfx))  # J7: 新規作成は self 自動採番 → (b) 飛ばし (c)
    pos = _positional_operands(operands)
    fb = _foreign_beads(pos, self_pfx)
    if fb:
        return ("b", msg_b(self_pfx, " ".join(fb)))
    return ("c", msg_c(self_pfx))


def classify(cmd, cwd, self_pfx):
    """cmd 中の最初に違反する bd 呼出しを (code, kind, reason) で返す(session 非依存の純 prefix-rule)。"""
    if not cmd:
        return 0, None, ""
    for core, _seg_cwd in iter_commands(cmd, cwd):
        if not core or os.path.basename(core[0]) != "bd":
            continue
        res = check_bd(core, self_pfx)
        if res:
            kind, reason = res
            return 2, kind, reason
    return 0, None, ""


def render(reason):
    return f"DENIED(bd): {reason}\n"


def decide(cmd, cwd, self_pfx):
    code, _kind, reason = classify(cmd, cwd, self_pfx)
    return code, (render(reason) if code else "")


def main_decide(cmd, cwd):
    """universal な最終判定(hook の実エントリ・逸脱(1)(3)(4))。
    walk-up で cwd の台帳を解決し、has-remote gate と fail 2 段を被せてから動的 self_pfx で decide する。"""
    beads = walk_up_beads(cwd)
    if beads is None:
        return 0, ""  # ⑦ 台帳外(git 外/.beads 皆無)→ graceful no-op

    remote = has_remote(beads)
    if remote is _REMOTE_UNKNOWN:
        # ★fail 2 段: config.yaml read 不能 → fail-open+loud(local-only project を brick しない)
        sys.stderr.write("[bd-guard] config.yaml 判定不能, failing open (local-only project を brick しない)\n")
        return 0, ""
    if remote is _REMOTE_NO:
        return 0, ""  # remote 未設定(local-only)→ coordination 不要 → no-op(逸脱(4))

    # remote-backed 台帳: coordination を効かせる。動的 self-prefix を解決。
    ident = resolve_self_prefix(beads)
    if ident is _LEDGER_UNREADABLE:
        # ★fail 2 段: identity present-but-unreadable → fail-closed(bare write を deny・moat 維持)。
        # self_pfx を「どの bead にも一致しない」sentinel にして全 write を block(exit2)へ落とす。
        return decide(cmd, cwd, _IMPOSSIBLE_PFX)
    if not isinstance(ident, str) or ident == "":
        # 非 dict/キー欠落/空 dolt_database(識別不能・parse 失敗ではない)→ 従来 fail-open(no-op・区別ルール②)。
        return 0, ""
    return decide(cmd, cwd, ident)


def main():
    if "--print-cmdtokens-lib" in sys.argv:
        if iter_commands is None:
            sys.stderr.write(f"[bd-guard] cmdtokens load failed: {_cmdtokens_load_error}\n")
            return 1
        sys.stdout.write(sys.modules["cmdtokens"].__file__ + "\n")
        return 0
    if "--self-test" in sys.argv:
        if iter_commands is None:
            print(f"FAIL: [preamble] cmdtokens load 失敗: {_cmdtokens_load_error}")
            print("bd-guard self-test: ABORTED (cmdtokens 未 load)")
            return 1
        if _session_load_error is not None:
            print(f"FAIL: [preamble] bdw_session load 失敗: {_session_load_error}")
            print("bd-guard self-test: ABORTED (bdw_session 未 load)")
            return 1
        rc = run_self_test()
        rc_dyn = run_dynamic_prefix_self_test()
        rc_f2 = run_fail2_self_test()
        return rc or rc_dyn or rc_f2
    try:
        raw = sys.stdin.read() if not sys.stdin.isatty() else ""
        data = json.loads(raw) if raw.strip() else {}
        cmd = (data.get("tool_input") or {}).get("command", "") or ""
        cwd = data.get("cwd") or os.getcwd()
    except Exception as e:
        sys.stderr.write(f"[bd-guard] input parse error, failing open: {e}\n")
        return 0
    try:
        code, msg = main_decide(cmd, cwd)
    except Exception as e:
        sys.stderr.write(f"[bd-guard] internal error, failing open: {e}\n")
        return 0
    if msg:
        sys.stderr.write(msg)
    return code


# --- token 判定 self-test(hermetic・self_pfx="sc" を固定注入して rule (a)(b)(c) を pin) -----------
def run_self_test():
    CWD = "/tmp"
    SP = "sc"  # 判定ロジックの検証用に固定 prefix を注入(動的解決は別 battery で検証)。
    B, A = 2, 0
    cases = [
        # (a) foreign target write deny
        ("bd -C /other/repo update un-1", B, "a", "foreign -C update"),
        ("bd --db /foreign.db create --title x", B, "a", "foreign --db create"),
        ("bd --global update sc-1", B, "a", "global write (self bead でも foreign target)"),
        ("bd -C /other update sc-1", B, "a", "foreign -C は self bead でも deny"),
        ("bd -Cother update sc-1", B, "a", "foreign -C glued"),
        ("bd update sc-1 -C /other", B, "a", "foreign -C after subcmd (cobra persistent)"),
        ("bd -C /other dolt push", B, "a", "foreign dolt push deny (kind a 不変)"),
        # foreign read allow
        ("bd -C /other show un-1", A, None, "foreign read: show"),
        ("bd -C /other --readonly update un-1", A, None, "readonly forces read → allow"),
        ("bd --readonly update sc-1", A, None, "readonly allow (self bead)"),
        # (b) 非 self bead への bare write deny
        ("bd update un-4sf --notes x", B, "b", "non-self update"),
        ("bd close un-1 un-2", B, "b", "non-self close multi"),
        ("bd update un-1 sc-2", B, "b", "mixed: one non-self → deny"),
        ("bd update --status closed un-9", B, "b", "flag-first: foreign id after --status → deny (J5)"),
        ("bd update --status closed --assignee me un-3", B, "b", "flag-first: skip --assignee value, catch un-3"),
        # ★prefix-collision: foreign prefix が self prefix の文字列前置(dash 無し startswith 誤分類の pin)。
        ("bd update scr-1 --notes x", B, "b", "collision: 'scr-1'.startswith('sc') だが self='sc' の foreign → deny(b)"),
        ("bd update sc2-1 --notes x", B, "b", "collision: 'sc2-1' も self='sc' の foreign → deny(b)"),
        ("bd close scr-1 scribe-9", B, "b", "collision multi: scr/scribe とも foreign → deny(b)"),
        # (c) self bare write → bdw funnel
        ("bd update sc-1 --notes x", B, "c", "self bare update → bdw"),
        ("bd create --title x --type task", B, "c", "create (id 無し self 付与) → bdw (J7)"),
        ("bd q implement un-9 handler", B, "c", "J7: q bare title with id-form word → c"),
        ('bd q "fix un-9 bug"', B, "c", "J7: q quoted title → c"),
        ("bd update sc-1 --assignee un-bot", B, "c", "J5: flag value un-bot 誤検出せず (self → c)"),
        ("bd frobnicate sc-1", B, "c", "J1: 未知 subcmd は write 扱い (self → c)"),
        ("bd frobnicate un-1", B, "b", "J1: 未知 subcmd + foreign bead → deny"),
        # ★逸脱(2): self dolt push/pull → bdw funnel(c) / commit/status は allow
        ("bd dolt push", B, "c", "★self dolt push → bdw funnel(c) (J2 bare-allow 反転)"),
        ("bd dolt pull", B, "c", "★self dolt pull → bdw funnel(c) (新規 funnel ケース)"),
        ("bd dolt commit -m x", A, None, "dolt commit self = 同期点 allow (funnel 対象外)"),
        ("bd dolt status", A, None, "dolt status read allow"),
        # J6 高危険 write
        ("bd sql \"UPDATE issues SET status='closed' WHERE id='un-1'\"", B, "a", "J6: sql UPDATE → deny(a)"),
        ("bd sql \"SELECT * FROM issues\"", B, "a", "J6: sql SELECT も一律 deny(a)"),
        ("bd batch -f x", B, "a", "J6: batch file → deny(a)"),
        ("bd import < dump.jsonl", B, "a", "J6: import → deny(a)"),
        # read allow
        ("bd show un-1", A, None, "show read (foreign id でも read allow)"),
        ("bd list --status open", A, None, "list read"),
        ("bd ready", A, None, "ready read"),
        ("bd export", A, None, "export read"),
        ("bd", A, None, "bd 単体"),
        # repo
        ("bd repo list", A, None, "repo list = read allow"),
        ("bd repo sync", B, "c", "repo sync = local-DB mutate → bdw"),
        ("bd -C /other repo sync", B, "a", "foreign repo target → deny(a)"),
        # dep / link
        ("bd dep list sc-1", A, None, "dep list read"),
        ("bd dep add sc-1 un-2", B, "c", "J3 cross-rig: self depends on foreign → bdw(c)"),
        ("bd dep add un-1 sc-2", B, "b", "dep add: foreign dependent → deny(b)"),
        ("bd link sc-1 un-2", B, "c", "link cross-rig: self dependent + foreign depends-on → c"),
        ("bd link un-1 sc-2", B, "b", "link: foreign dependent → deny(b)"),
        # launcher / inline / FP
        ("sudo bd update un-1", B, "b", "launcher: sudo"),
        ('bash -c "bd update un-1"', B, "b", "launcher: bash -c"),
        ("cd /x && bd update sc-1", B, "c", "cd + self bare → bdw"),
        ("bdw update sc-1", A, None, "bdw wrapper bypasses guard (basename != bd)"),
        ('echo "bd update un-1"', A, None, "FP: echo containing bd update"),
        ("bd dolt push && rm -f x", B, "c", "★compound: self dolt push→c (funnel) + rm skip"),
        ("bd show un-1 && bd update sc-9", B, "c", "compound: read ok, then self write → bdw"),
    ]
    failures = []
    for cmd, want_code, want_kind, label in cases:
        try:
            code, kind, _reason = classify(cmd, CWD, SP)
        except Exception as e:
            failures.append(f"[EXC] {label}: {cmd!r} -> {e}")
            continue
        if code != want_code:
            failures.append(f"[code {want_code} expected] {label}: {cmd!r} -> got code={code} kind={kind}")
        elif want_kind is not None and kind != want_kind:
            failures.append(f"[kind {want_kind!r} expected] {label}: {cmd!r} -> got kind={kind!r}")
    if failures:
        for f in failures:
            print("FAIL:", f)
        print(f"bd-guard token self-test: {len(failures)}/{len(cases)} FAILED")
        return 1
    print(f"bd-guard token self-test: {len(cases)}/{len(cases)} OK")
    return 0


# --- 動的 self-prefix self-test(fixture 台帳を 2 prefix で作り対 pin・un-37xq 必須) --------------
# SELF_PREFIX を定数移植せず cwd の dolt_database で解決することを、dolt_database=un と =sc の
# fixture 台帳(remote あり)を作り「un session: un-bare→c / sc-bare→b」「sc session: sc-bare→c /
# un-bare→b」の対で pin する。定数移植 mutant はここで RED 化する。
def run_dynamic_prefix_self_test():
    import tempfile
    import shutil
    failures = []
    tmpdirs = []

    def mk(dolt_db, remote=True):
        root = tempfile.mkdtemp(prefix="bdguard-dyn-")
        tmpdirs.append(root)
        os.makedirs(os.path.join(root, ".beads"))
        with open(os.path.join(root, ".beads", "metadata.json"), "w", encoding="utf-8") as f:
            json.dump({"database": "dolt", "dolt_database": dolt_db}, f)
        with open(os.path.join(root, ".beads", "config.yaml"), "w", encoding="utf-8") as f:
            f.write('sync.remote: "git+https://example.com/x.git"\n' if remote else "# no remote\n")
        return root

    try:
        un_root = mk("un")
        sc_root = mk("sc")
        # ★検証は main_decide の返す (code, msg) だけで行う(classify を直接呼んで迂回しない)。
        # msg は msg_a/b/c が **動的解決した prefix**('un-'/'sc-')と kind marker を埋め込むため、定数移植
        # mutant(ident→"sc")は un session で msg が 'sc-'/foreign marker に反転してここで RED 化する。
        #   want_pfx = msg に現れるべき '<pfx>-' / want_mark = kind の marker 文字列(funnel=c / foreign=b)。
        FUNNEL_MARK = "bdw 経由"                       # msg_c 固有
        FOREIGN_MARK = "prefix bead への bd write は禁止"  # msg_b 固有
        cases = [
            (un_root, "bd update un-1 --notes x", 2, "'un-'", FUNNEL_MARK, "un session: un self → funnel(c)・un- prefix"),
            (un_root, "bd update sc-1 --notes x", 2, "'un-'", FOREIGN_MARK, "un session: sc foreign → deny(b)・un- prefix"),
            (sc_root, "bd update sc-1 --notes x", 2, "'sc-'", FUNNEL_MARK, "sc session: sc self → funnel(c)・sc- prefix"),
            (sc_root, "bd update un-1 --notes x", 2, "'sc-'", FOREIGN_MARK, "sc session: un foreign → deny(b)・sc- prefix"),
            (un_root, "bd show sc-1", 0, None, None, "un session: foreign read は allow"),
        ]
        for cwd, cmd, want_code, want_pfx, want_mark, label in cases:
            try:
                code, msg = main_decide(cmd, cwd)
            except Exception as e:
                failures.append(f"[EXC main_decide] {label}: {e}")
                continue
            if code != want_code:
                failures.append(f"[code {want_code}] {label}: got {code}")
                continue
            if want_pfx is not None and want_pfx not in msg:
                # 動的 prefix が msg に現れない=定数移植で prefix が反転(RED)。
                failures.append(f"[prefix {want_pfx}] {label}: msg に無い -> {msg!r}")
            if want_mark is not None and want_mark not in msg:
                # kind marker(funnel=c / foreign=b)が反転(定数移植で self↔foreign 誤分類)。
                failures.append(f"[mark {want_mark!r}] {label}: msg に無い -> {msg!r}")
    finally:
        for d in tmpdirs:
            shutil.rmtree(d, ignore_errors=True)
    if failures:
        for f in failures:
            print("FAIL:", f)
        print(f"bd-guard dynamic-prefix self-test: {len(failures)}/{len(cases)} FAILED")
        return 1
    print("bd-guard dynamic-prefix self-test: OK")
    return 0


# --- fail 2 段 self-test(逆極性を fixture で対 pin・入替 mutant で 2 case 反転) ------------------
def run_fail2_self_test():
    import tempfile
    import shutil
    failures = []
    tmpdirs = []

    def mk(dolt_db_json, config_text, meta_unreadable=False):
        root = tempfile.mkdtemp(prefix="bdguard-f2-")
        tmpdirs.append(root)
        os.makedirs(os.path.join(root, ".beads"))
        meta = os.path.join(root, ".beads", "metadata.json")
        if meta_unreadable:
            with open(meta, "w", encoding="utf-8") as f:
                f.write("{ this is not valid json")  # present-but-unreadable(区別ルール①=fail-closed)
        elif dolt_db_json == "__nondict__":
            with open(meta, "w", encoding="utf-8") as f:
                json.dump([1, 2, 3], f)  # parse 成功だが非 dict(区別ルール②=fail-open・None へ畳む)
        elif dolt_db_json is not None:
            with open(meta, "w", encoding="utf-8") as f:
                json.dump({"database": "dolt", "dolt_database": dolt_db_json}, f)
        if config_text is not None:
            with open(os.path.join(root, ".beads", "config.yaml"), "w", encoding="utf-8") as f:
                f.write(config_text)
        return root

    REMOTE_CFG = 'sync.remote: "git+https://example.com/x.git"\n'
    WRITE = "bd update un-1 --notes x"  # remote+un session なら kind b で deny(2)
    try:
        # ① identity present-but-unreadable + remote → fail-closed(bare write deny=2)
        r_unreadable = mk(None, REMOTE_CFG, meta_unreadable=True)
        # ② config.yaml read 不能 + identity OK → fail-open+loud(0)。config.yaml を dir にして read 失敗を作る。
        r_cfgbad = mk("un", None)
        os.makedirs(os.path.join(r_cfgbad, ".beads", "config.yaml"))  # dir 化 → open で IsADirectoryError
        # ③ remote 未設定(local-only)→ no-op(0)
        r_noremote = mk("un", "# no remote here\n")
        # ④ 台帳外(.beads 皆無)→ no-op(0)
        r_noledger = tempfile.mkdtemp(prefix="bdguard-f2-noledger-"); tmpdirs.append(r_noledger)
        # ⑤ 正常 remote+un → deny(2)(対照: fail-closed でなく通常 rule で deny)
        r_ok = mk("un", REMOTE_CFG)
        # ⑥ 区別ルール②(fail-open 側・①の逆極性): remote-backed でも識別子が確定できない場合は no-op(0)。
        r_empty = mk("", REMOTE_CFG)            # 空 dolt_database('')→ ident=="" → no-op
        r_nondict = mk("__nondict__", REMOTE_CFG)  # 非 dict metadata → resolve None → no-op

        cases = [
            (r_unreadable, WRITE, 2, "① identity unreadable + remote → fail-closed deny(2)"),
            (r_cfgbad, WRITE, 0, "② config.yaml read 不能 → fail-open+loud(0)"),
            (r_noremote, WRITE, 0, "③ remote 未設定(local-only)→ no-op(0)"),
            (r_noledger, WRITE, 0, "④ 台帳外(.beads 皆無)→ no-op(0)"),
            (r_ok, WRITE, 2, "⑤ 正常 remote+un session → 通常 rule で deny(2)"),
            (r_ok, "bd show un-1", 0, "⑤' 正常 session でも read は allow(0)"),
            (r_empty, WRITE, 0, "⑥a remote + 空 dolt_database → no-op(区別ルール②・①の逆極性)"),
            (r_nondict, WRITE, 0, "⑥b remote + 非dict metadata → no-op(区別ルール②)"),
        ]
        for cwd, cmd, want, label in cases:
            try:
                code, _msg = main_decide(cmd, cwd)
            except Exception as e:
                failures.append(f"[EXC] {label}: {e}")
                continue
            if code != want:
                failures.append(f"[code {want}] {label}: got {code}")
    finally:
        for d in tmpdirs:
            shutil.rmtree(d, ignore_errors=True)
    if failures:
        for f in failures:
            print("FAIL:", f)
        print(f"bd-guard fail2 self-test: {len(failures)} FAILED")
        return 1
    print("bd-guard fail2 self-test: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
