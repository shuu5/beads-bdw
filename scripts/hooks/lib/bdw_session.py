#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 共有 lib: universal bd-write-guard 用の「動的 self-prefix 解決」+「has-remote 判定」。
#
# PROVENANCE ───────────────────────────────────────────────────────────────────
# un-37xq(universal funnel guard の full-port)Leg-B の walk-up session lib。
# 移植元 = scribe scripts/hooks/lib/scribe_session.py / scriptorium orch_session.py の三値 walk-up 解決。
# ただし ★意図的逸脱(un-37xq 契約・必須 echo back): 移植元は SELF_PREFIX を **定数**("sc"/"orch")で持つが、
#   本 lib は SELF_PREFIX を **定数移植しない**。universal guard は全13台帳で発火するため、cwd の
#   `.beads/metadata.json` の dolt_database を **実行時に self-prefix として解決**する(前提 dolt_database==
#   bead-id prefix は全13台帳で実測一致)。定数を移植すると単一台帳にしか効かない/他台帳を false-BLOCK する。
#
# 提供する 3 プリミティブ(いずれも subprocess 非依存=filesystem stat/read のみ・決して die しない):
#   walk_up_beads(cwd)      : cwd から上方向へ最初に見つかる `.beads` dir の絶対パス(無ければ None)。
#   resolve_self_prefix(bd) : `.beads/metadata.json` の dolt_database を三値解決
#                             (str / _LEDGER_UNREADABLE / None)。動的 self-prefix の SSOT。
#   has_remote(beads_dir)   : `.beads/config.yaml` の col0 `sync.remote:` 行 scan で三値
#                             (_REMOTE_YES / _REMOTE_NO / _REMOTE_UNKNOWN)。remote-backed 台帳のみ
#                             guard を効かせ、local-only project を universal blast radius で brick しない。
#
# 三値の理由(fail 2 段・un-37xq 契約):
#   - identity present-but-unreadable(metadata は在るが read/parse 失敗)→ _LEDGER_UNREADABLE →
#     guard は **fail-closed**(self ledger かもしれず moat を瞬間的に開かない)。
#   - has-remote 判定不能(config.yaml read/parse 不能)→ _REMOTE_UNKNOWN → guard は **fail-open+loud**
#     (local-only project を brick しない・universal blast radius の人間承認済み逸脱)。
#   両者は **逆極性**。入れ替える mutant で 2 case が反転する(tests/bd-write-guard-mutants.sh M-fail2)。

import os
import json
import re

# 三値 walk-up 解決の sentinel(orch-5yl/scribe port)。metadata がファイルとして存在するが識別子
# (dolt_database)を read/parse 失敗で確定できなかった状態。str でない一意 object ゆえ実値と衝突しない。
# None(= metadata 皆無=台帳外)とは別状態(fail-closed/fail-open の分岐点)。
_LEDGER_UNREADABLE = object()

# has-remote の三値 sentinel。
_REMOTE_YES = object()      # col0 `sync.remote: <値>` 行あり = remote-backed(coordination 対象)。
_REMOTE_NO = object()       # config.yaml は読めたが sync.remote 行なし = local-only(guard no-op)。
_REMOTE_UNKNOWN = object()  # config.yaml read/parse 不能 = 判定不能(fail-open+loud)。

# col0 の flat dotted-key `sync.remote:` に非空値が続く行(実フリート format=`sync.remote: "git+https://…"`)。
# ★負例(no-match): 先頭空白付き(indented)/`#` コメント/nested `sync:`+`  remote:`/値なし `sync.remote:`。
#   `.` は literal(実キーは flat dotted)。行位置・末尾改行に非依存(行単位 scan)。
_SYNC_REMOTE_RE = re.compile(r'^sync\.remote:[ \t]*(?!\s*(#|$))\S')


def walk_up_beads(cwd):
    """cwd から上方向へ最初に見つかる `.beads` dir の絶対パスを返す(無ければ None)。
    bd 自身の台帳解決と同じ walk-up。例外は握り潰し None(hook が die しない契約)。"""
    try:
        d = os.path.abspath(cwd or os.getcwd())
    except Exception:
        return None
    prev = None
    while d and d != prev:
        beads = os.path.join(d, ".beads")
        try:
            if os.path.isdir(beads):
                return beads
        except Exception:
            return None
        prev, d = d, os.path.dirname(d)
    return None


def resolve_self_prefix(beads_dir):
    """`.beads/metadata.json` の dolt_database を三値解決する(動的 self-prefix の SSOT)。

      - str  : metadata が存在し read/parse 成功・dict で dolt_database キーを持つ(正常)。
               空文字列 '' も str ゆえ本状態(呼出側が扱う)。
      - _LEDGER_UNREADABLE : metadata は **ファイルとして存在するが open/read もしくは JSON parse が
               例外**(present-but-unreadable=区別ルール①)。guard は fail-closed。
      - None : metadata 不在(beads_dir=None 含む) / parse 成功だが非 dict / dolt_database キー欠落
               (区別ルール②・parse 失敗ではない=従来 fail-open を保つ)。

    例外は握り潰し決して伝播させない。"""
    if not beads_dir:
        return None
    meta = os.path.join(beads_dir, "metadata.json")
    try:
        present = os.path.isfile(meta)
    except Exception:
        return None
    if not present:
        return None
    try:
        with open(meta, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return _LEDGER_UNREADABLE  # 区別ルール①(read/parse 失敗)→ fail-closed 側
    if not isinstance(data, dict):
        return None  # 区別ルール②(非 dict・parse 成功)→ fail-open 側
    db = data.get("dolt_database")
    return db if isinstance(db, str) else None


def has_remote(beads_dir):
    """`.beads/config.yaml` を col0 `sync.remote:` 行 scan で三値判定する(subprocess 非依存=ホットパス)。

      - _REMOTE_YES     : col0 `sync.remote: <非空値>` 行あり = remote-backed(coordination 対象)。
      - _REMOTE_NO      : config.yaml を読めたが sync.remote 行なし = local-only(guard no-op)。
      - _REMOTE_UNKNOWN : config.yaml が **存在するが read 失敗** = 判定不能(fail-open+loud)。
                          config.yaml 不在は _REMOTE_NO(remote 未設定と同義=local-only)。

    予測: 実フリートの remote-backed 台帳は必ず col0 flat `sync.remote: "…"` を持つ(実測)。nested
    `sync:`+`  remote:` や indented/commented は **no-match**(config-format-pin bats が SSOT)。"""
    if not beads_dir:
        return _REMOTE_NO
    cfg = os.path.join(beads_dir, "config.yaml")
    try:
        exists = os.path.exists(cfg)
    except Exception:
        return _REMOTE_UNKNOWN
    if not exists:
        return _REMOTE_NO  # config.yaml 皆無 = remote 未設定と同義 = local-only
    # exists=True で open/read が失敗(権限なし・dir・特殊ファイル・I/O error)は「在るが read 不能」
    # =判定不能 → _REMOTE_UNKNOWN(fail-open+loud 側・区別ルール逆極性)。os.path.isfile を presence gate に
    # 使うと dir-config が「不在=NO」に畳まれ UNKNOWN と識別できないため、exists + open-catch で判別する。
    try:
        with open(cfg, "r", encoding="utf-8") as f:
            text = f.read()
    except Exception:
        return _REMOTE_UNKNOWN
    for line in text.splitlines():
        if _SYNC_REMOTE_RE.match(line):
            return _REMOTE_YES
    return _REMOTE_NO
