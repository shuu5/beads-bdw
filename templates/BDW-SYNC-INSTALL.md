# bdw-sync Layer3(systemd user timer)per-machine インストール手順

bd write 協調 hook の **Layer3** = セッション非依存に自台帳を pull+push する systemd user timer。
Layer1(`bin/bdw` の WRITE 直前 pull)/ Layer2(admin Stop hook 即 push)を取りこぼしても、
timer が周期的に鮮度を回収する **fail-safe backstop**。

> 注: この timer が回す `bdw-sync pull-push` は **pull+push のみ**で、pull 後の
> `issues.jsonl` mirror-export(auto-export)は**含まない**(`pull_push_impl` =
> `do_pull`→`do_push` のみ・export 呼出なし)。issues.jsonl mirror の再生成を担うのは
> `bin/bdw` の WRITE 経路(`maybe_auto_export`)だけで、L3 timer は Dolt 台帳の
> pull/push に閉じる。※本注記は L3 経路の事実共有であり、runbook の scope や mirror 要求を変えない。

> ⚠ **per-machine 手動・常時起動サーバー機のみ。自動配線しない**(un-10h5 契約)。
> ノート PC 等の間欠起動機は Layer1/Layer2 で十分。timer は「常時起動でセッション外でも
> 台帳を触りうるサーバー機」だけに、その機のオペレータが明示的に enable する。

## 前提

- `beads-bdw` plugin が `~/.claude/plugins/beads-bdw/` に配置済み(`bin/bdw` / `bin/bdw-sync` が実行可能)。
- 対象台帳 repo に `bd dolt remote`(または `.beads/config.yaml` の `sync.remote`)が設定済み。
  remote 未設定の台帳は timer が起動しても **graceful no-op**(何もしない)。
- `systemctl --user` が使える(user systemd instance が動いている)。常時起動サーバーでセッション
  外でも動かすには linger を有効化: `sudo loginctl enable-linger "$USER"`。

## インストール(台帳 1 つあたり)

template unit を user unit dir に配置し、台帳の **絶対パス**を `systemd-escape` して instance を enable する。

```sh
# 1) template を user unit dir へ配置(初回のみ)
mkdir -p ~/.config/systemd/user
cp ~/.claude/plugins/beads-bdw/templates/bdw-sync@.service ~/.config/systemd/user/
cp ~/.claude/plugins/beads-bdw/templates/bdw-sync@.timer   ~/.config/systemd/user/
systemctl --user daemon-reload

# 2) 対象台帳(例: /home/me/ledger)の timer を enable + 即時起動
LEDGER=/home/me/ledger
systemctl --user enable --now "bdw-sync@$(systemd-escape "$LEDGER").timer"
```

`%i`(instance 名)= `systemd-escape` した台帳 root 絶対パス。`%I` は service 内で unescape され
`bdw-sync pull-push --lock --repo %I` の `--repo` に渡る(timer には cwd が無いため必須)。

## 既知の対象インスタンス(per-machine)

- **ipatho-1 / orch(scriptorium)clone**: `/home/shuu5/projects/local-projects/scriptorium`
  (dolt remote = `git+https://github.com/shuu5/scriptorium.git` 設定済 = graceful no-op ではなく
  pull-push 対象になりうる)。escape 後 instance = `bdw-sync@-home-shuu5-projects-local\x2dprojects-scriptorium.timer`。
  ただし **enable は無条件で行わない**: orch を universal sync に include するかは orch-ese5 裁定
  (a)案「条件付き include 予定」が gate で、その 2 前提 — ① un-10h5 land 済み実層での scriptorium
  側 re-spike が GREEN(Seq-2/Seq-5)、② 実 GitHub dolt-remote 往復(push/pull round-trip)を
  非 sandbox admin が確認 — の**双方充足後**に限る。裁定確定(un-7fxm 返送)前・前提未充足の段階では
  enable しない。bespoke な ipatho-1 専用 timer は作らず、上記 template@ 流用で enable する。

```sh
# enable は上記 2 前提充足後のみ。今は記録のみ(実行しない)。
LEDGER=/home/shuu5/projects/local-projects/scriptorium
systemctl --user enable --now "bdw-sync@$(systemd-escape "$LEDGER").timer"
#  → instance: bdw-sync@-home-shuu5-projects-local\x2dprojects-scriptorium.timer
#  前提(確認済): sync.remote(git+https://github.com/shuu5/scriptorium.git)設定済・linger=yes 済
```

## 動作確認

```sh
LEDGER=/home/me/ledger
INST="bdw-sync@$(systemd-escape "$LEDGER")"
systemctl --user list-timers | grep bdw-sync        # 次回発火時刻
systemctl --user start "$INST.service"              # 手動で 1 回起動
journalctl --user -u "$INST.service" -n 30 --no-pager   # ログ(pull/push 結果・conflict banner)
```

- **transient**(offline/unreachable)は degrade(exit 0)し journal に warn を残す → 次周期で回収。
- **genuine merge conflict** は `bdw-sync` が block+loud(exit 3)して journal に残す。復旧は
  (1) bootstrap 再 hydrate(既定・remote 権威で上書き)/(2) dolt CLI 手動 merge。timer は次周期で再試行。

> ⚠ **lock 保持時間の制約(共有サーバーで worker と同居する場合)**: `pull-push --lock` は
> `bin/bdw` と同じ machine-wide flock を掴んで worker WRITE と直列化する。remote が unreachable/
> 低速な間に 1 回の flock で pull+push を直列保持すると最悪 `2×BDW_SYNC_NET_TIMEOUT_SECS` 掴み続け、
> worker 側の flock 待ち `BDW_LOCK_TIMEOUT`(既定 60s)を超えると同一台帳の worker WRITE が
> `fail-closed`(exit 1)で一斉に転ぶ。そこで Layer3 は pull と push を**別々の flock 区間に分割**し、
> 1 回あたりの保持を単一 op(~`BDW_SYNC_NET_TIMEOUT_SECS`)に抑えている。運用制約として
> **`BDW_SYNC_NET_TIMEOUT_SECS`(+ `timeout -k` の grace 5s)< worker の `BDW_LOCK_TIMEOUT`** を保つこと
> (既定 30+5=35s < 60s は満たす)。net timeout を上げる場合は worker の lock timeout も併せて見直す。

## 周期の変更

既定は起動 2 分後に初回・以後 15 分毎(`OnUnitActiveSec=15min`)。変えるには drop-in を置く:

```sh
mkdir -p ~/.config/systemd/user/"$INST.timer.d"
cat > ~/.config/systemd/user/"$INST.timer.d"/override.conf <<'EOF'
[Timer]
OnUnitActiveSec=5min
EOF
systemctl --user daemon-reload
systemctl --user restart "$INST.timer"
```

Layer1 の freshness 閾値は `BDW_SYNC_THROTTLE_SECS`(既定 900=15min)。timer 周期と揃えると
Layer1 と Layer3 が同じ marker(`$HOME/.cache/bdw-locks/bd-sync-<repo_id>.marker`)を共有して
二重 pull を避ける(L1/L3 閾値共有=invariant⑤)。timer 側で閾値を変えたい場合は service の
`Environment=BDW_SYNC_THROTTLE_SECS=<秒>` を drop-in で足す(ただし pull-push は throttle 無視で
必ず pull するため、timer 周期そのものが実効の同期間隔)。

## アンインストール

```sh
LEDGER=/home/me/ledger
INST="bdw-sync@$(systemd-escape "$LEDGER")"
systemctl --user disable --now "$INST.timer"
```
