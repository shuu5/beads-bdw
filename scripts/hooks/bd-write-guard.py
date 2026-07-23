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
# mol の create-like sub-subcommand(un-aukl): pour/wisp は proto(mol-*)から self 台帳へ新規 bead を
# spawn する create 同型操作。positional proto-id(mol-feat 等)は BD_ID_RE に一致するが write 対象の
# foreign bead ではないため、CREATE_LIKE の J7 と同じく rule(b) 検査を飛ばし funnel(c) へ落とす。
# ★免除は {pour, wisp} 厳密限定: burn/squash/bond/dissolve/distill は**既存 mol への write** で
#   positional が本物の foreign 対象になりうる。ここへ拡張すると rule(b) が沈黙し b→c 反転=fail-open
#   (owner-2 moat 破り)。拡張禁止は mutant M-molmoat が RED で守る(免除除去側は M-molfp)。
MOL_CREATE_LIKE = {"pour", "wisp"}
# self dolt funnel 対象(逸脱(2)): push/pull は flock 迂回 race を封鎖するため bdw funnel(c)。
DOLT_FUNNEL = {"push", "pull"}

# 値取り flag(次トークンを値として消費する)。write subcommand の `bd help <sub>` の型注記
# (string/strings/int/stringArray)から網羅列挙する(証跡 probe: flagscan-un-a0t9.local.py)。
# ★bool flag を入れてはならない: bool 直後の本物の foreign positional bead id が「値」として食われ
#   rule(b) が沈黙する=fail-closed(安全側過剰 block)→fail-open(owner-2 moat すり抜け)への極性反転で
#   元の FP より悪化する。禁止例: --claim --stdin --ephemeral --persistent --no-history --history
#   --allow-empty-description --force --no-inherit-labels --sandbox。
# ★値が bead id そのものになる flag は意図的に非登録: 値を消費すると当該 bead が foreign 検査面から
#   消える。過剰 block(FP)は安全側だが取りこぼしは moat 破りゆえ、判断が割れる箇所は fail-closed に
#   倒す(既登録の --parent/--blocked-by/--with は既存挙動として不変・本 bead の scope 外)。
#   非登録の id 値 flag(probe 実測・write 面): --of(duplicate) / --blocks,-b(dep, gate create) /
#   --id(admin compact, migrate issues) / --ids-file(migrate issues) / --issue-id(audit record) /
#   --attach(mol pour) / --deps / --waits-for / --event-target。
#   ★--attach(mol pour)追補(un-aukl): mol pour/wisp は MOL_CREATE_LIKE の create-like 免除で
#     rule(b) 検査自体を飛ばすため --attach 隣接 FP は解決済=SUBCMD_VAL_FLAGS への登録は不要のまま。
#     登録しても positional proto FP は残り(false-green)、id 値を消費する trap だけが増える(登録禁止)。
#   ★この非登録は self-test の [id 値 flag 非登録=fail-closed pin] 群と mutant M-idval が守る。
#   網羅を仕上げる後続作業者へ: probe 出力を機械的に流し込むとこの集合が混入し、全 green のまま
#   moat が破れる。追加時は必ず上記除外集合を差し引くこと。
# ★arity 衝突により非登録(write 面で bool 用法を持つ): --check(doctor=値 / setup=bool) /
#   --project(*-sync=値 / setup=bool) / --team(linear sync=値 / init=bool)。SUBCMD_BOOL_OVERRIDES で
#   救えるが FP 実害が観測されていないため fail-closed 側に据え置く。
# 網羅状況(verified): 上記 2 つの除外集合を除き、READ_SUBCMDS/HIGH_DANGER_WRITE/CREATE_LIKE 以外の
# write subcommand に出現する値取り flag は全て登録済み(probe 出力と機械照合)。
SUBCMD_VAL_FLAGS = {
    "--status", "-s", "--reason", "-r", "--priority", "-p", "--notes", "-n",
    "--assignee", "-a", "--owner", "--title", "-t", "--type", "--design",
    "--acceptance", "--message", "-m", "--with", "--label", "-l", "--milestone",
    "--parent", "--estimate", "--actor", "--limit", "--format", "--sort",
    "--from", "--to", "--depends-on", "--blocked-by", "--description", "-d",
    # update(un-a0t9 floor)
    "--add-label", "--append-notes", "--await-id", "--body-file", "--defer",
    "--design-file", "--due", "--external-ref", "--metadata", "--remove-label",
    "--session", "--set-labels", "--set-metadata", "--spec-id", "--unset-metadata", "-e",
    # create(複数形 --labels は単数 --label と別 flag) / close / comment / note / dep add / delete
    "--labels", "--reason-file", "--file", "--from-file",
    # gate create / merge-slot acquire / swarm create
    "--timeout", "--holder", "--coordinator",
    # ↓ 残余 write subcommand の網羅(probe 出力と機械照合・上記除外集合は差し引き済み)
    # defer / cook / vc / audit / remember / worktree / admin / compact / gc / prune / purge
    "--until", "--mode", "--prefix", "--search-path", "--var", "--strategy",
    "--kind", "--model", "--prompt", "--response", "--error", "--exit-code", "--tool-name",
    "--key", "--branch", "--tier", "--batch-size", "--workers", "--summary",
    "--days", "--older-than", "--pattern", "--group", "--path",
    # dep list/tree / gate discover / mol / migrate / rules
    "--direction", "--max-depth", "--max-age", "--for", "--range", "--as", "--ref",
    "--attach-type", "--include", "--threshold", "--output", "-o",
    # init / setup / doctor / config / notion / federation / 各種 tracker sync
    "--add", "--backend", "--database", "--role", "--destroy-token", "--remote",
    "--agents-file", "--agents-profile", "--agents-template",
    "--server-host", "--server-port", "--server-socket", "--server-user",
    "--proxied-server-config-path", "--proxied-server-log-path", "--proxied-server-root-path",
    "--proxied-server-external-host", "--proxied-server-external-port",
    "--proxied-server-external-user", "--proxied-server-external-socket-path",
    "--proxied-server-external-keep-alive",
    "--proxied-server-external-tls-cert-path", "--proxied-server-external-tls-key-path",
    "--migration", "--orchestrator-duplicates-threshold", "--source", "--url",
    "--peer", "--user", "-u", "--password", "--sovereignty",
    "--issues", "--state", "--states", "--exclude-type", "--types",
    "--area-path", "--iteration-path",
}

# 同名 flag が subcommand によって arity を変える箇所(flat 集合では表現不能=どちらに倒しても
# 一方の subcommand が壊れる)。value 集合から subcmd 単位で差し引いて arity を確定する。
# ここに列挙しないと bool flag 直後の foreign bead id が値として食われ rule(b) が沈黙する(fail-open)。
# 実測(flagscan-un-a0t9.local.py)の衝突: --acceptance/--description/--design/--notes/--title は
# create/update では値取りだが `bd edit` では「どのフィールドを $EDITOR で開くか」の bool、
# -a/-n/-e は update/create では値取りだが gate 配下(list/discover/check)では bool、
# -p は update/create では値取りだが `mol show` では bool。
# ★粒度は top-level subcmd。sub-subcommand 間でも割れる場合(gate list -a=bool / gate discover -a=値)は
#   安全側(bool=消費しない=fail-closed)へ倒す。過剰 block は FP で済むが取りこぼしは moat 破りのため。
SUBCMD_BOOL_OVERRIDES = {
    "edit": {"--acceptance", "--description", "--design", "--notes", "--title"},
    "gate": {"-a", "-n", "-e"},
    "mol": {"-p"},
}

# ★override は top-level subcmd の「リテラル名」で引かれるため、bd 側の subcommand alias を
#   正規化しないと alias 経路だけ override が外れ bool flag が値取り扱いに戻る=fail-open
#   (実測: `bd mol show -p un-9` は (b) だが `bd protomolecule show -p un-9` は -p が un-9 を
#   値として食い (c) へ反転し rule(b) が沈黙した)。SUBCMD_BOOL_OVERRIDES のキーが持つ alias は
#   ここへ全て登録すること(verified: `bd help mol` → 'Aliases: mol, protomolecule'。
#   edit/gate に alias 無し)。他 subcmd の alias(close←done 等)は override 非対象ゆえ不要。
SUBCMD_ALIASES = {
    "protomolecule": "mol",
}

# ★操作対象の bead id を **別ファイル/stdin** から取る write flag(= HIGH_DANGER_WRITE と同型)。
#   これらは SUBCMD_VAL_FLAGS 登録済ゆえ値(パス)は消費され positional が空になり、_foreign_beads の
#   検査面が空 → funnel(c) で **無検査のまま foreign bead への write が通る**(fail-open)。ファイルの
#   中身は guard から機械検査不能であり、値がパス形か id 形かで挙動が割れる形状依存も持ち込みたくない。
#   よって「id を外部ソースから取る write」という modality 単位で rule(d)(msg_d)一律 deny する。
#   ★delete 決め打ちにしない: 同型の兄弟(dep add --file / migrate issues --ids-file)を取りこぼすと
#     不変量の適用漏れが構造的に固定される(un-a0t9 self-review finding #1)。
#   probe 実測(flagscan-un-a0t9.local.py)で「値が id 群のファイル」なのは以下の 3 flag のみ。
#   他の *-file 系(--reason-file/--body-file/--design-file/comment|note の --file/create --file)は
#   本文テキストであり id を持たないため対象外(過剰 block を避ける)。batch --file は
#   HIGH_DANGER_WRITE で既に deny 済。
#   キーは top-level subcmd 名(bd の alias `migrate issues` ≡ `migrate-issues` は両方登録)。
#   sub-subcommand 粒度に絞らないのは安全側(read 用法が無いことを probe で確認: dep は add のみ /
#   migrate は issues のみ / delete は sub-subcommand 無し)。
EXTERNAL_ID_SOURCE_FLAGS = {
    "delete": {"--from-file"},
    "dep": {"--file"},
    "migrate": {"--ids-file"},
    "migrate-issues": {"--ids-file"},
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
    """bd のグローバルフラグを消費し (sub, operands, foreign, has_readonly, has_help) を返す。
    移植元と同一の骨格に un-aukl item(3) の -h/--help 通しを追加: sub 確定後の -h/--help は
    値取り flag の値位置(--notes --help)との弁別が要るため operand 面へ通し check_bd 側で判定する。"""
    has_C = has_db = has_global = has_readonly = has_help = False
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
        if t in ("-h", "--help"):
            # ★un-aukl item(3): 完全一致のみ(--helpx 等の prefix 誤検出禁止)。sub 前の出現は
            #   global help 確定(値位置は上の --actor 等の値消費が先に食うためここへ来ない)。
            if sub is None:
                has_help = True
            else:
                operands.append(t)
            i += 1
            continue
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
    return sub, operands, (has_C or has_db or has_global), has_readonly, has_help


def _val_flags(sub):
    """当該 subcommand における値取り flag 集合(base から subcmd 別 bool override を差し引く)。"""
    sub = SUBCMD_ALIASES.get(sub, sub)  # alias 経路で override が外れる fail-open を封鎖
    override = SUBCMD_BOOL_OVERRIDES.get(sub)
    return SUBCMD_VAL_FLAGS - override if override else SUBCMD_VAL_FLAGS


def _has_help_operand(operands, sub):
    """operand 面の -h/--help(完全一致のみ・--helpx 等の prefix 誤検出禁止)を検出する(un-aukl item(3))。
    ★fail-open 封鎖 3 面(help でないのに allow へ落とすと write が素通りする):
      (1) 値取り flag の直後(値位置)の -h/--help は cobra/pflag が flag でなく「値」として消費し
          command が実行される(bd update sc-1 --notes --help は notes='--help' の write)→ help 扱いしない。
      (2) `--` 以降は cobra が flag 解釈を止める(positional 扱い)→ help 扱いしない。
      (3) SUBCMD_VAL_FLAGS 非登録の dash flag(意図的非登録の id 値 flag --of/--attach/--waits-for 等・
          bool override 側に倒した flag を含む)は guard から arity 不明で、pflag は非 bool flag の
          次 token を dash 有無に関係なく値として消費する → 直後の -h/--help が値位置でありうるため
          即 return False(fail-closed=help 扱いしない→従来判定へ落とす)。help 側へ倒さない取りこぼしは
          deny FP で安全側、help 側へ倒すと deny→allow 反転=owner-2/funnel moat 破り(un-aukl self-review)。
          非登録 id 値 flag 集合を val 側へ列挙しないのは意図的: 集合の二重管理ドリフトを避け、未知の
          将来 flag も自動で fail-closed に落とす。glued(--flag=値)形のみ例外的に読み飛ばして継続する
          (値を inline 消費し次 token を食わない=arity 既知 0 で、直後の --help は真の help flag)。"""
    val_flags = _val_flags(sub)
    i, n = 0, len(operands)
    while i < n:
        a = operands[i]
        if a == "--":
            return False
        if a in ("-h", "--help"):
            return True
        if a.startswith("-"):
            if "=" in a:
                i += 1  # glued 形は次 token を消費しない → help 判定を継続してよい
                continue
            if a in val_flags:
                i += 2  # 登録済値取り flag: 次 token は値位置 → help 扱いしない
                continue
            return False  # ★un-aukl fail-closed: 未登録 flag は arity 不明 → help 扱いしない
        i += 1
    return False


def _external_id_source_flag(sub, operands):
    """当該 write が「対象 bead id を外部ソース(file/stdin)から取る」flag を含むなら flag 名を返す。
    glued(--flag=値)形も同一に扱う(形状依存を持ち込まない)。"""
    flags = EXTERNAL_ID_SOURCE_FLAGS.get(SUBCMD_ALIASES.get(sub, sub))
    if not flags:
        return None
    for o in operands:
        if o.split("=", 1)[0] in flags:
            return o.split("=", 1)[0]
    return None


def _positional_operands(operands, sub=None):
    """operands 全体から positional token を順序保持で抽出(interspersed flag 貫通)。
    値取り flag(当該 subcmd の arity 基準)は次トークンを値として読み飛ばす=id 形の値を
    positional と誤認して foreign 判定する FP を防ぐ(un-a0t9)。"""
    val_flags = _val_flags(sub)
    out = []
    i, n = 0, len(operands)
    while i < n:
        a = operands[i]
        if a.startswith("-"):
            if a in val_flags and "=" not in a:
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
    pos = _positional_operands(operands, "link" if is_link else "dep")
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
    pos = _positional_operands(operands, "repo")
    action = pos[0] if pos else None
    if action is None or action in REPO_READ:
        return None
    if foreign:
        return ("a", msg_a(self_pfx))
    return ("c", msg_c(self_pfx))


def check_bd(core, self_pfx):
    """bd コマンドの token 列を判定。(kind, reason) or None(allow)。self_pfx は動的解決値。"""
    sub, operands, foreign, has_readonly, has_help = _parse_bd(core[1:])
    if sub is None:
        return None
    if has_readonly:
        return None
    # ★un-aukl item(3): -h/--help(完全一致)付き呼出しは cobra が command 非実行で help 表示のみ(実測済)
    #   = read。write subcmd + --help(bd update --help / bd mol pour --help 等)の rule(c) deny FP を
    #   短絡 allow で解消する。値位置/`--` 以降の -h/--help は _has_help_operand が help 扱いしない。
    if has_help or _has_help_operand(operands, sub):
        return None
    if sub in READ_SUBCMDS:
        return None

    if sub == "dolt":
        # J2 + ★逸脱(2): foreign→deny(a) / self push|pull→bdw funnel(c) / 他 dolt(commit/status/…)→allow。
        if foreign:
            return ("a", msg_a(self_pfx))
        pos = _positional_operands(operands, sub)
        action = pos[0] if pos else None
        if action in DOLT_FUNNEL:
            return ("c", msg_c(self_pfx))  # ★flock 迂回 race 封鎖: self dolt push/pull も bdw funnel
        return None  # dolt commit/status/start/stop 等は同期点/read = allow

    # ★rule(d) 汎化: 対象 id を外部ソース(file/stdin)に持つ write は modality 単位で一律 deny。
    #   dep/migrate も対象ゆえ各 dispatch より **前** に置く(EXTERNAL_ID_SOURCE_FLAGS 参照)。
    if _external_id_source_flag(sub, operands) is not None:
        return ("a", msg_d(self_pfx))

    if sub == "dep":
        return _check_dep(operands, foreign, self_pfx)
    if sub == "link":
        return _check_dep(operands, foreign, self_pfx, is_link=True)
    if sub == "repo":
        return _check_repo(operands, foreign, self_pfx)
    if sub in HIGH_DANGER_WRITE:
        return ("a", msg_d(self_pfx))  # J6: id 不明高危険 write は一律 deny
    # (`delete --from-file` を含む外部 id ソース系は上の rule(d) 汎化分岐で処理済)

    if foreign:
        return ("a", msg_a(self_pfx))
    if sub in CREATE_LIKE:
        return ("c", msg_c(self_pfx))  # J7: 新規作成は self 自動採番 → (b) 飛ばし (c)
    pos = _positional_operands(operands, sub)
    # ★un-aukl item(1): mol pour/wisp は proto から self へ spawn する create 同型 → J7 と同じく
    #   (b) 飛ばし (c)。positional proto-id(mol pour mol-feat)と --attach 隣接値(--attach mol-x)の
    #   foreign 誤検出 FP を一挙解消する(alias 正規化後の sub==mol でのみ判定=protomolecule 経路も被覆)。
    if SUBCMD_ALIASES.get(sub, sub) == "mol" and pos and pos[0] in MOL_CREATE_LIKE:
        return ("c", msg_c(self_pfx))
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
        # ★un-a0t9: 値取り flag の網羅(未登録だと値が positional 扱いになり id 形の値を foreign 誤検出=FP)
        ("bd update sc-1 --append-notes gate-pending", B, "c", "self+value flag → funnel(c) [un-a0t9 core]"),
        ("bd update sc-1 --add-label gate-pending", B, "c", "add-label 値消費 → c [worker gate-label path]"),
        ("bd update sc-1 --set-labels done-review", B, "c", "set-labels 値消費 → c"),
        ("bd update sc-1 --append-notes=glued-val", B, "c", "glued 形は c 維持"),
        ("bd update sc-1 --remove-label stale-wip", B, "c", "remove-label 値消費 → c"),
        ("bd update sc-1 --external-ref gh-9", B, "c", "external-ref 値消費 → c"),
        ("bd update sc-1 --due next-monday", B, "c", "due 値消費 → c"),
        ("bd update sc-1 -e 60 --spec-id spec-7", B, "c", "-e(int)/--spec-id 値消費 → c"),
        ("bd close sc-1 --reason-file close-note", B, "c", "close --reason-file 値消費 → c"),
        ("bd comment sc-1 --file review-notes", B, "c", "comment --file 値消費 → c"),
        # ★un-a0t9: delete --from-file は対象 id を別ファイルに持ち機械検査不能 → rule(d) 一律 deny(kind a)
        ("bd delete --from-file dead-ids", B, "a", "delete --from-file(positional 無し): 無検査一括 delete → deny(d) [destructive fail-open 封鎖]"),
        ("bd delete --from-file /tmp/ids.txt", B, "a", "パス形でも同様に deny(d) [形状非依存]"),
        ("bd delete sc-1 --from-file dead-ids", B, "a", "self positional 併用でも --from-file があれば deny(d)"),
        ("bd delete --from-file=dead-ids", B, "a", "glued 形の --from-file も deny(d)"),
        ("bd delete sc-1", B, "c", "--from-file 無しの self delete は従来どおり funnel(c) [過剰 block 非導入]"),
        # ★un-a0t9(self-review #1): rule(d) 汎化 — 同型の兄弟経路も同一 modality として deny(a)
        ("bd dep add --file deps.jsonl", B, "a", "dep add --file(JSONL 一括辺): 対象 id が別ファイル → deny(d) [兄弟経路]"),
        ("bd dep add --file -", B, "a", "dep add --file -(stdin)も同様に deny(d)"),
        ("bd dep add --file=deps.jsonl", B, "a", "glued 形の dep add --file も deny(d)"),
        ("bd migrate issues --ids-file ids.txt", B, "a", "migrate issues --ids-file: 対象 id が別ファイル → deny(d) [兄弟経路]"),
        ("bd migrate-issues --ids-file ids.txt", B, "a", "migrate-issues alias でも deny(d)"),
        ("bd migrate issues --id un-9", B, "b", "inline --id 形は従来どおり foreign 検出(b) [file 形との対称性]"),
        ("bd dep add sc-1 sc-2", B, "c", "--file 無しの self dep add は従来どおり c [過剰 block 非導入]"),
        # ★un-a0t9: fail-open 非導入の pin(値 flag 登録が foreign 検出を潰していないこと)
        ("bd update un-1 --append-notes note-x", B, "b", "foreign target+value flag: foreign 依然検出 → b [fail-open 非導入の証拠]"),
        ("bd update sc-1 --claim un-9", B, "b", "bool --claim 直後の foreign positional → 依然(b) [moat pin]"),
        ("bd update sc-1 --stdin un-9", B, "b", "bool --stdin 直後の foreign → 依然(b) [moat pin]"),
        ("bd close -f un-9", B, "b", "-f は close で bool(--force) → 直後 foreign 依然(b) [arity 衝突 pin]"),
        # ★un-a0t9: subcmd 別 arity(同名 flag が subcmd で値/bool を変える箇所の moat pin)
        ("bd edit --title un-9", B, "b", "edit の --title は bool → 直後 foreign 依然(b) [arity override pin]"),
        ("bd edit --notes un-9", B, "b", "edit の --notes は bool → 依然(b) [arity override pin]"),
        ("bd gate list -a un-9", B, "b", "gate list の -a は bool → 依然(b) [arity override pin]"),
        ("bd gate discover -n un-9", B, "b", "gate discover の -n は bool → 依然(b) [arity override pin]"),
        ("bd gate check -e un-9", B, "b", "gate check の -e は bool → 依然(b) [arity override pin]"),
        ("bd mol show -p un-9", B, "b", "mol show の -p は bool → 依然(b) [arity override pin]"),
        ("bd protomolecule show -p un-9", B, "b", "mol alias でも -p は bool → 依然(b) [alias moat pin]"),
        ("bd update sc-1 --notes x --title y", B, "c", "update では --notes/--title は値取り(override は edit 限定)"),
        # ★un-a0t9: 兄弟 write subcommand の網羅(update だけでなく defer/cook/vc/audit/remember/worktree/admin)
        ("bd defer sc-1 --until next-monday", B, "c", "defer --until 値消費 → c(update --due と同型 FP の封鎖)"),
        ("bd cook --mode dry-run", B, "c", "cook --mode 値消費 → c"),
        ("bd vc merge --strategy fast-forward", B, "c", "vc merge --strategy 値消費 → c"),
        ("bd audit record --kind tool-use", B, "c", "audit record --kind 値消費 → c"),
        ("bd remember --key project-notes", B, "c", "remember --key 値消費 → c"),
        ("bd worktree create sc-1 --branch feat-x", B, "c", "worktree create --branch 値消費 → c"),
        ("bd admin compact --tier hot-tier", B, "c", "admin compact --tier 値消費 → c"),
        # ★un-a0t9: 値が bead id 自体になる flag は非登録=fail-closed(foreign 検査面から消さない)
        # この 3 件が (b) を保つことが moat の非空虚な pin。mutant M-idval が RED 化を保証する。
        ("bd duplicate sc-1 --of un-9", B, "b", "--of の値 un-9 は foreign 検出対象のまま → b [id 値 flag 非登録=fail-closed pin]"),
        ("bd update sc-1 --event-target un-9", B, "b", "--event-target 非登録 → foreign 依然検出 b [id 値 flag 非登録=fail-closed pin]"),
        ("bd gate create sc-1 --waits-for un-9", B, "b", "--waits-for 非登録 → foreign 依然検出 b [id 値 flag 非登録=fail-closed pin]"),
        ("bd gate create sc-1 --blocks un-9", B, "b", "--blocks(id 値)非登録 → foreign 依然検出 b [id 値 flag 非登録=fail-closed pin]"),
        ("bd admin compact --id un-9", B, "b", "--id(id 値)非登録 → foreign 依然検出 b [id 値 flag 非登録=fail-closed pin]"),
        # ★un-aukl item(1): mol pour/wisp は create 同型(proto → self spawn)= (b) 飛ばし (c)
        ("bd mol pour mol-feat", B, "c", "un-aukl FP 解消: pour の positional proto-id を foreign 誤検出しない → c"),
        ("bd mol wisp mol-feat", B, "c", "un-aukl FP 解消: wisp も create 同型 → c"),
        ("bd protomolecule pour mol-feat", B, "c", "un-aukl: alias 経路(protomolecule)でも create-like 免除 → c"),
        ("bd mol pour sc-1 --attach mol-x", B, "c", "un-aukl: --attach 隣接値も免除で解消(SUBCMD_VAL_FLAGS 登録不要) → c"),
        # ★un-aukl item(1) moat: 免除は {pour,wisp} 厳密限定(burn/squash/bond は既存 mol への write のまま b)
        ("bd mol burn un-9", B, "b", "un-aukl moat: mol burn は免除外 → foreign 依然検出 b"),
        ("bd mol squash un-9", B, "b", "un-aukl moat: mol squash は免除外 → b"),
        ("bd mol bond un-9 mol-x", B, "b", "un-aukl moat: mol bond は免除外 → b"),
        # ★un-aukl item(3): write subcmd + -h/--help は cobra 非実行(help 表示のみ)= allow
        ("bd update --help", A, None, "un-aukl FP 解消: bd update --help → allow"),
        ("bd create --help", A, None, "un-aukl FP 解消: bd create --help → allow"),
        ("bd mol pour --help", A, None, "un-aukl FP 解消: bd mol pour --help → allow"),
        ("bd update sc-1 -h", A, None, "un-aukl FP 解消: -h 完全一致も allow"),
        # ★un-aukl item(3) moat: help 扱いの境界(完全一致のみ・値位置/-- 以降は help でない)
        ("bd update sc-1 --helpx", B, "c", "un-aukl moat: --helpx は help でない(prefix 誤検出禁止) → 従来判定 c"),
        ("bd update un-9 --notes y", B, "b", "un-aukl moat: --help 無しの foreign write は従来どおり b 不変"),
        ("bd update un-9 --notes --help", B, "b", "un-aukl moat: 値位置の --help は値(cobra は write 実行) → help 扱いせず b"),
        ("bd update sc-1 -- --help", B, "c", "un-aukl moat: -- 以降の --help は positional → help 扱いせず c"),
        # ★un-aukl self-review moat: 非登録 flag(arity 不明)直後の --help は値位置でありうる → fail-closed
        #   (help 扱いせず従来判定へ)。deny→allow 反転(fail-open)の封鎖 pin 群。mutant M-helpval が守る。
        ("bd duplicate un-9 --of --help", B, "b", "un-aukl moat: 非登録 id 値 flag(--of)の値位置 --help は help でない → foreign b 維持"),
        ("bd mol pour sc-1 --attach --help", B, "c", "un-aukl moat: --attach の値位置 --help も help でない → funnel c 維持(bare 迂回封鎖)"),
        ("bd gate create sc-1 --waits-for --help --blocks un-9", B, "b", "un-aukl moat: --waits-for 値位置 --help を help 扱いせず foreign un-9 を b 検出"),
        ("bd migrate issues --ids-file --help", B, "a", "un-aukl moat: --ids-file 値位置 --help でも rule(d) deny a 維持"),
        ("bd update sc-1 --event-target --help", B, "c", "un-aukl moat: --event-target 値位置 --help も help でない → 従来 c"),
        ("bd update sc-1 --notes=x --help", A, None, "un-aukl: glued 形(--notes=x)は次 token 非消費 → --help は真の help = allow"),
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
