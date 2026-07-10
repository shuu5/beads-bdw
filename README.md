# beads-bdw

`bdw` — bd の WRITE を flock で直列化するラッパの **単一 SSOT** を提供する beads-substrate plugin。

## 何か

`bin/bdw` は `bd` の WRITE サブコマンド(`create` / `update` / `close` / `dep` …)を「マシン共通
flock」で直列化し、READ(`show` / `list` / `query` …)は lock 無しで素通しするラッパ。
全 bd-writer repo はこの canonical を **薄い shim 経由で consume** する(自前のロジックを持たない)。

## なぜ

`.beads/embeddeddolt` は embedded Dolt = **single-writer**。anchor とその全 worktree は git
common-dir 経由で物理 1 つの DB を共有する。N 並列 worker が同一 issue へ read-modify-write 系の
write(`bd update --append-notes` 等)を並行実行すると last-writer-wins で **lost-update** が起きる
(実測: 15 並列 append-notes → 5 件消失)。`bdw` はその write 群を flock で直列化して防ぐ。

従来は同じ `bdw` 実装が scriptorium / uns / scribe 等に **3 コピー散在**しており drift の温床だった。
本 plugin はそれを 1 箇所に集約し、各 repo は shim で参照するだけにする(orch-wvd grill 2026-06-23 合意)。

## 設計の核(不可侵)

- **fail-closed**: lock dir を確保できなければ書かず `exit 1`。**`/tmp` 等への fallback は持たない**
  (合意外の別 dir を掴んで直列化が黙って破れる窓=静かな lost-update 復活を構造的に塞ぐ)。
- **self-contained**: 外部 lib を一切 source しない。lock_dir は inline で
  `${BDW_LOCK_DIR:-$HOME/.cache/bdw-locks}`。`HOME` 未設定 + `BDW_LOCK_DIR` 未設定は解決不能 → fail-closed。
- **basename は "bdw" 固定**: orchestrator の bd-write-guard は basename != "bd" のコマンドを素通しするため、
  本ツールは無改修で guard を通る。**basename を変えないこと**。

## consumer の使い方

1. 本 plugin を `~/.claude/plugins/beads-bdw/` に配置する(canonical = `bin/bdw`)。
2. 各 bd-writer repo に `templates/bdw-shim` を `scripts/bdw` としてコピーし、実行権限を付ける。
   shim は `${BEADS_BDW:-$HOME/.claude/plugins/beads-bdw/bin/bdw}` で canonical を解決し、
   見つからなければ fail-closed(loud に停止)、見つかれば `exec` で丸投げするだけ。
3. 並列 worker は write を必ず `scripts/bdw <subcmd> ...` 経由で行う(素の `bd` write を使わない)。

```sh
# 例(repo 側)
cp ~/.claude/plugins/beads-bdw/templates/bdw-shim scripts/bdw
chmod +x scripts/bdw
scripts/bdw update orch-1 --append-notes "..."
```

## lock-dir / lock-file export contract

consumer(scribe の gen-sandbox `allowWrite` 等)や selftest が「bdw が実際に使う lock の場所」を
参照するための問い合わせ経路。どちらも **bd を呼ばず** 解決値だけを stdout に出す(mkdir もしない):

```sh
bin/bdw lock-dir    # 解決済み lock_dir を stdout に出して exit 0
bin/bdw lock-file   # WRITE で実際に掴む lock file 絶対パスを stdout に出して exit 0(対象 repo 内で呼ぶ)
```

- `lock-dir`: `BDW_LOCK_DIR` が設定されていればその値、無ければ `$HOME/.cache/bdw-locks` を返す。
- `lock-file`: `<lock_dir>/bd-write-<repo_id>.lock`。`repo_id` は cwd の git common-dir(物理パス正規化済み)の
  sha256 先頭 16 桁ゆえ **対象 repo 内で呼ぶ**(WRITE パスと同一の解決経路)。git 外なら `$PWD` へ fallback。

いずれも解決不能(`HOME` 未設定 + `BDW_LOCK_DIR` 未設定)は `exit 1`(空ではなく非 0 で consumer に誤った値を信用させない)。

**なぜ `lock-file` が要るか**: consumer/selftest が lock file のパスを自前で mirror 再計算すると、bdw 本体と
算出がズレて **別 lock を掴み直列化が黙って破れる窓**(un-7nw)になる。問い合わせに一本化してその窓を構造的に塞ぐ。
実際 `bdw-selftest.sh` の READ-under-lock 節はこの問い合わせで holder lock を算出する(mirror を撤去済み)。

## 環境変数(任意)

| var | 既定 | 意味 |
| --- | --- | --- |
| `BDW_BD_BIN` | PATH 上の `bd` | bd 実体 |
| `BDW_LOCK_DIR` | `$HOME/.cache/bdw-locks` | lock 配置 dir(マシン共通の固定絶対パス) |
| `BDW_LOCK_TIMEOUT` | `60` | flock 待機秒。超過で fail-closed |
| `BDW_NO_AUTOEXPORT` | (未設定=export 有効) | `=1` で WRITE 後の `.beads/issues.jsonl` auto-export を抑止(batch escape hatch) |
| `BEADS_BDW`(shim) | `$HOME/.claude/plugins/beads-bdw/bin/bdw` | shim が解決する canonical の場所 |

## auto-export(WRITE 後の issues.jsonl mirror 再生成)

WRITE(`create` / `update` / `close` / `dep` …)が **rc==0** で完了した後、`bdw` は **同一 flock 保持中**に
`bd export -o <root>/.beads/issues.jsonl` を実行して mirror(`issues.jsonl`)を再生成する。
これは bd v1.1.0 embedded mode の auto-export 退行で mirror が凍結し、orchestrator の pull hydrate が
**stale を読む**問題(orch-89v)への恒久 fix。sandbox 外で走る bdw consumer には exec consume 経由で
一括で効く。**ただし sandboxed worker(scribe bwrap 等)は例外**: sandbox の `allowWrite` は `.beads`
直下 runtime エントリと lock file だけを grant し `.beads` dir 自体は grant しない(governance 保護・
sc-nd6/OG-1)一方、`bd export -o` は `.beads` 直下に temp を作り renameat する=`.beads` dir write を要する。
よって sandbox 内では export が構造的に不能で、`bdw` は毎 write の warn を避けるため **silent skip** する
(下記「発火条件」)。sandboxed worker の mirror 再生成は **admin/orchestrator の sandbox 外 gate-time
export に依存**する(この canonical fix は sandbox 内までは届かない)。

- **export 先 root** = git common-dir の親 dir(**anchor root**)。anchor + 全 worktree は物理 1 DB を
  共有し worktree の `.beads` は tracked ファイルのみゆえ、mirror も anchor の 1 つに収束させる
  (`repo_id` 解決と同じ「物理 DB と 1 対 1」哲学)。
- **発火条件**: `rc==0` かつ `BDW_NO_AUTOEXPORT != 1` かつ subcmd が `export` でない(二重 export 回避)
  かつ export 先 `.beads` dir が実在 **かつ書込可能**。git 外 / `.beads` 不在 / `.beads` dir が
  read-only(sandbox の bwrap bind・RO mount)は **silent skip**(write は成功のまま・warn も出さない)。
- **fail-open**: export 失敗は stderr へ warn するだけで **WRITE の exit code を変えない**
  (Dolt への write は既に commit 済・mirror だけ stale になる)。抑止は `BDW_NO_AUTOEXPORT=1`。
  なお `.beads` が read-only な sandbox では上記 silent skip に落ちるため warn は出ない(構造的に
  export 不能な環境で毎 write 警告を撒かない)。残る warn は「書けるはずが失敗した」真の異常のみ。
- **無限ループ排除**: export は `bd` を直接呼ぶ(`bdw` 再帰なし)。READ 系(`list` / `show` …)では
  export は走らない(lock も取らない素通しパスのため)。

## selftest

```sh
bash bdw-selftest.sh
```

検証する命題: (a) READ 素通し / (b) WRITE が flock 直列化される(lost-update しない) /
(c) lock 取得不能で fail-closed / (d) basename != bd で guard を素通しする性質 /
(e) `bdw lock-dir` が lock_dir を出して exit 0 / (f) `bdw lock-file` が lock file 絶対パスを出して exit 0
(かつ selftest 自身がこの問い合わせで holder lock を算出する) /
(g) auto-export: WRITE 後に mirror 再生成 / `BDW_NO_AUTOEXPORT=1` で skip / export 失敗でも WRITE の
exit code=0 温存(fail-open) / READ では auto-export が走らない。

3 値判定: `PASS`(exit 0・RED 再現 ∧ 全 hard 次元 ok) / `INCONCLUSIVE`(exit 2・hard は全 ok だが
RED 非再現=timing) / `FAIL`(exit 1・hard 次元のいずれか失敗)。INCONCLUSIVE は競合環境で再実行するか
`BDW_SELFTEST_N` を上げて RED を再現させること。
