#!/usr/bin/env bats
# tests/bdw-sync.bats — bd write 協調 hook Layer1 seam(bin/bdw-sync)+ bin/bdw 統合の deliverable テスト。
#
# un-10h5 Leg-A の検証 SSOT(tracked)。各不変条件に positive+negative control を張り、
# tests/bdw-sync-mutants.sh の named mutant で「mutant 適用で当該 case が FAIL する」非空虚性を実証する
# (対応表は DONE 報告 / tests/bdw-sync-mutants.sh 冒頭)。
#
# 決定検証(classifier/throttle/marker/自台帳のみ/block)は fake bd stub で dolt 非依存に回す。
# real e2e(happy pull・genuine conflict)は実 bd + file:// remote で non-vacuous に回す。
# core tool(bats/bd/dolt/flock/jq)不在は skip でなく FAIL(契約: skip 禁止)。

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  # mutant differential(tests/bdw-sync-mutants.sh)が mutated copy を差し込むための override 口。
  BDW="${BDW_OVERRIDE:-$REPO_ROOT/bin/bdw}"
  SYNC="${BDW_SYNC_OVERRIDE:-$REPO_ROOT/bin/bdw-sync}"
  # core tool present-or-FAIL(skip 禁止)
  for t in bash git grep sed stat; do
    command -v "$t" >/dev/null 2>&1 || { echo "FAIL: core tool '$t' absent"; return 1; }
  done
  WORK="$BATS_TEST_TMPDIR/work"
  export BDW_LOCK_DIR="$BATS_TEST_TMPDIR/locks"
  mkdir -p "$WORK" "$BDW_LOCK_DIR"
  CALLS="$BATS_TEST_TMPDIR/calls"; : >"$CALLS"
  STUB="$BATS_TEST_TMPDIR/bin/bd-stub"; mkdir -p "$(dirname "$STUB")"
  # fake bd: argv を CALLS に記録し、SCENARIO 用 env に基づき canned 出力+rc を返す。
  cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$*" in
  "dolt remote list")
    if [ "${FAKE_REMOTE:-yes}" = yes ]; then echo "origin               file:///fake/bare"; else echo "No remotes configured."; fi
    exit 0 ;;
  "dolt pull"*)
    printf '%s\n' "${FAKE_PULL_OUT:-Pull complete.}"; exit "${FAKE_PULL_RC:-0}" ;;
  "dolt push"*)
    printf '%s\n' "${FAKE_PUSH_OUT:-Push complete.}"; exit "${FAKE_PUSH_RC:-0}" ;;
  *) exit 0 ;;
esac
STUBEOF
  chmod +x "$STUB"
  export CALLS
  export BDW_BD_BIN="$STUB"
  # in_syncable_repo を満たす最小 fake repo(git + .beads dir。実 bd 不要)。
  ( cd "$WORK" && git init -q && git config user.email t@e.com && git config user.name t && mkdir -p .beads )
}

# ─── ⑥ genuine conflict → exit 3(block) ────────────────────────────────────────
@test "invariant6-conflict: genuine merge conflict は exit 3 (block)" {
  run env FAKE_REMOTE=yes FAKE_PULL_RC=1 \
      FAKE_PULL_OUT="Error: merge origin/main: merge conflicts in issues require operator resolution; merge aborted and working set restored" \
      BDW_BD_BIN="$STUB" CALLS="$CALLS" BDW_LOCK_DIR="$BDW_LOCK_DIR" bash -c 'cd "'"$WORK"'" && "'"$SYNC"'" pull'
  [ "$status" -eq 3 ]
  [[ "$output" == *"GENUINE merge conflict"* ]]
}

# ─── ⑥ transient → exit 0 + warn(degrade・negative control vs conflict) ──────────
@test "invariant6-transient: transient failure は exit 0 で degrade(warn 有)" {
  run env FAKE_REMOTE=yes FAKE_PULL_RC=1 \
      FAKE_PULL_OUT="Error: dial tcp: connection refused" \
      BDW_BD_BIN="$STUB" CALLS="$CALLS" BDW_LOCK_DIR="$BDW_LOCK_DIR" bash -c 'cd "'"$WORK"'" && "'"$SYNC"'" pull'
  [ "$status" -eq 0 ]
  [[ "$output" == *"transient"* ]]
}

# ─── ⑦ no remote → graceful no-op(exit 0・warn 無・pull 呼ばない) ─────────────────
@test "invariant7-noremote: remote 未設定は silent no-op(pull を試みない)" {
  run env FAKE_REMOTE=no BDW_BD_BIN="$STUB" CALLS="$CALLS" BDW_LOCK_DIR="$BDW_LOCK_DIR" \
      bash -c 'cd "'"$WORK"'" && "'"$SYNC"'" pull'
  [ "$status" -eq 0 ]
  [ -z "$output" ]                          # warn を出さない
  ! grep -q "dolt pull" "$CALLS"            # pull を試みない
}

# ─── OK: rc0 pull → exit 0・marker touched ───────────────────────────────────────
@test "ok-pull: 正常 pull は exit 0 で marker を touch する" {
  m="$(cd "$WORK" && "$SYNC" marker-path)"
  [ ! -e "$m" ]
  run env FAKE_REMOTE=yes FAKE_PULL_RC=0 BDW_BD_BIN="$STUB" CALLS="$CALLS" BDW_LOCK_DIR="$BDW_LOCK_DIR" \
      bash -c 'cd "'"$WORK"'" && "'"$SYNC"'" pull'
  [ "$status" -eq 0 ]
  [ -e "$m" ]
}

# ─── ⑤ throttle: fresh marker → pull を skip / stale → pull ──────────────────────
@test "invariant5-throttle-fresh: fresh marker は pull を skip する" {
  m="$(cd "$WORK" && "$SYNC" marker-path)"; mkdir -p "$(dirname "$m")"; : >"$m"   # now=fresh
  run env FAKE_REMOTE=yes FAKE_PULL_RC=0 BDW_SYNC_THROTTLE_SECS=900 \
      BDW_BD_BIN="$STUB" CALLS="$CALLS" BDW_LOCK_DIR="$BDW_LOCK_DIR" \
      bash -c 'cd "'"$WORK"'" && "'"$SYNC"'" pull-if-stale'
  [ "$status" -eq 0 ]
  ! grep -q "dolt pull" "$CALLS"            # fresh ゆえ pull しない
}

@test "invariant5-throttle-stale: stale marker は pull する" {
  m="$(cd "$WORK" && "$SYNC" marker-path)"; mkdir -p "$(dirname "$m")"; : >"$m"
  touch -d '1 hour ago' "$m"
  run env FAKE_REMOTE=yes FAKE_PULL_RC=0 BDW_SYNC_THROTTLE_SECS=60 \
      BDW_BD_BIN="$STUB" CALLS="$CALLS" BDW_LOCK_DIR="$BDW_LOCK_DIR" \
      bash -c 'cd "'"$WORK"'" && "'"$SYNC"'" pull-if-stale'
  [ "$status" -eq 0 ]
  grep -q "dolt pull" "$CALLS"              # stale ゆえ pull する
}

# ─── ⑤ marker disjoint: 禁則集合と非交差・bd-sync-* 名・lock dir 配下 ────────────────
@test "invariant5-marker-disjoint: marker 名が禁則集合と disjoint" {
  m="$(cd "$WORK" && "$SYNC" marker-path)"
  case "$m" in
    */.beads/last-sync|*/.beads/last-touched|*/.beads/scribe-heartbeat|*/.beads/export-state.json)
      echo "禁則名: $m"; return 1 ;;
  esac
  [[ "$m" == "$BDW_LOCK_DIR/bd-sync-"*".marker" ]]   # 名前規約 + lock dir 配下
  [[ "$m" != *"/.beads/"* ]]                          # .beads/ 配下でない
}

# ─── ① 自台帳のみ: pull は foreign flag(-C/--db/--global)を付けない ──────────────────
@test "invariant1-self-only: pull は -C/--db/--global を付けず自台帳のみ" {
  run env FAKE_REMOTE=yes FAKE_PULL_RC=0 BDW_BD_BIN="$STUB" CALLS="$CALLS" BDW_LOCK_DIR="$BDW_LOCK_DIR" \
      bash -c 'cd "'"$WORK"'" && "'"$SYNC"'" pull'
  [ "$status" -eq 0 ]
  # 記録された pull 呼出しが厳密に "dolt pull"(foreign flag 無し)であること。
  grep -q '^dolt pull$' "$CALLS"
  ! grep -qE 'dolt pull.*(-C|--db|--global|--directory)' "$CALLS"
}

# ─── bin/bdw 統合: sync exit 3 で WRITE を block(bd を実行しない) ─────────────────────
@test "bdw-block: bin/bdw は sync exit 3 で WRITE を block し bd を実行しない" {
  # temp dir に bin/bdw のコピー + exit 3 を返す fake bdw-sync を並べ、統合分岐を単体検証する。
  bindir="$BATS_TEST_TMPDIR/bdwbin"; mkdir -p "$bindir"
  cp "$BDW" "$bindir/bdw"
  cat > "$bindir/bdw-sync" <<'FAKE'
#!/usr/bin/env bash
exit 3
FAKE
  chmod +x "$bindir/bdw-sync"
  # bd を「呼ばれたら痕跡を残す」stub に(block されれば痕跡は残らないはず)
  bdstub="$BATS_TEST_TMPDIR/bd-write-stub"
  cat > "$bdstub" <<STUBEOF
#!/usr/bin/env bash
echo "BD_RAN \$*" >> "$BATS_TEST_TMPDIR/bd-ran"
exit 0
STUBEOF
  chmod +x "$bdstub"
  : > "$BATS_TEST_TMPDIR/bd-ran"
  run env BDW_BD_BIN="$bdstub" BDW_LOCK_DIR="$BDW_LOCK_DIR" \
      bash -c 'cd "'"$WORK"'" && "'"$bindir"'/bdw" update x-1 --append-notes probe'
  [ "$status" -eq 3 ]                                  # block=fail-closed
  ! grep -q "BD_RAN update" "$BATS_TEST_TMPDIR/bd-ran" # bd(WRITE)は実行されていない
}

# ─── bin/bdw self-contained pin(serializer 核は外部 lib を source しない) ─────────────
@test "bdw-self-contained: bin/bdw は外部 lib を source/. しない" {
  # bin/bdw 単体 scope。source / . による外部ファイル読込が無いこと(walk-up lib 等を誤検出しない)。
  run grep -nE '^[[:space:]]*(source|\.)[[:space:]]+[^ ]' "$BDW"
  [ "$status" -ne 0 ]                                  # マッチ無し=source 行が無い
}

# ─── Layer3 runtime path: pull-push が do_pull→do_push を順に呼ぶ ─────────────────────
# finding un-10h5: Layer3 の唯一の runtime 入口 `pull-push` がテスト皆無=直列化 claim が未検証。
@test "pull-push: do_pull→do_push を順に呼ぶ(CALLS に pull と push 両方)" {
  run env FAKE_REMOTE=yes FAKE_PULL_RC=0 FAKE_PUSH_RC=0 \
      BDW_BD_BIN="$STUB" CALLS="$CALLS" BDW_LOCK_DIR="$BDW_LOCK_DIR" \
      bash -c 'cd "'"$WORK"'" && "'"$SYNC"'" pull-push'
  [ "$status" -eq 0 ]
  grep -q '^dolt pull$' "$CALLS"            # pull が走る
  grep -q '^dolt push$' "$CALLS"            # push も走る(直列)
}

# ─── Layer3 短絡: pull が genuine conflict なら push せず exit 3(pull_push_locked も同じ) ──
@test "pull-push-conflict: pull が conflict なら push せず exit 3" {
  run env FAKE_REMOTE=yes FAKE_PULL_RC=1 \
      FAKE_PULL_OUT="Error: merge origin/main: merge conflicts in issues require operator resolution; merge aborted and working set restored" \
      BDW_BD_BIN="$STUB" CALLS="$CALLS" BDW_LOCK_DIR="$BDW_LOCK_DIR" \
      bash -c 'cd "'"$WORK"'" && "'"$SYNC"'" pull-push'
  [ "$status" -eq 3 ]
  grep -q '^dolt pull$' "$CALLS"            # pull は試みた
  ! grep -q '^dolt push$' "$CALLS"          # conflict ゆえ push はしない(短絡)
}

# ─── Layer3 --lock: bin/bdw と同一 lock を尊重し、保持中は skip(bd を呼ばない) ────────────
# finding un-10h5: run_locked は load-bearing な直列化 seam。--lock が「bin/bdw の lock-file を
# 問い合わせ→同一 flock を掴む」ことと、lock 取得失敗時の skip 挙動を positive control で pin する。
# 別プロセスが同一 lock を排他保持中に pull --lock を叩くと、run_locked は flock を取れず skip
# (exit 0・次周期 timer で回収)して dolt を呼ばない。lock-file が別パスなら自由に取れて pull が
# 走り、この assert が破れる=同一 lock を掴んでいることの positive control。
@test "lock-coordination: --lock は bin/bdw の lock-file を尊重し保持中は skip する" {
  bindir="$BATS_TEST_TMPDIR/lockbin"; mkdir -p "$bindir"
  cp "$SYNC" "$bindir/bdw-sync"; chmod +x "$bindir/bdw-sync"
  lf="$BATS_TEST_TMPDIR/shared.lock"; : >"$lf"
  # fake bdw: lock-file 問い合わせに共有 lock パスを返す(他 subcmd は no-op)。
  cat > "$bindir/bdw" <<FAKE
#!/usr/bin/env bash
[ "\$1" = lock-file ] && { printf '%s\n' "$lf"; exit 0; }
exit 0
FAKE
  chmod +x "$bindir/bdw"
  # 別 OFD で lock を排他保持したまま pull --lock を叩く(run_locked は別 fd で取りに行き競合)。
  exec 7>"$lf"; flock -x 7
  run env FAKE_REMOTE=yes FAKE_PULL_RC=0 BDW_BD_BIN="$STUB" CALLS="$CALLS" \
      BDW_LOCK_DIR="$BDW_LOCK_DIR" BDW_LOCK_TIMEOUT=1 \
      bash -c 'cd "'"$WORK"'" && "'"$bindir"'/bdw-sync" pull --lock'
  flock -u 7; exec 7>&-
  [ "$status" -eq 0 ]                       # 取れず skip=exit 0(backstop・次周期回収)
  ! grep -q '^dolt pull$' "$CALLS"          # lock 保持中ゆえ dolt を呼んでいない(=同一 lock を尊重)
}

# ═══ real e2e(実 bd + file:// remote・non-vacuous) ═══════════════════════════════
# core tool present-or-FAIL(skip 禁止)。real repo を throwaway に作り自台帳保護のもと検証する。
_need_real_tools() {
  for t in bd jq flock dolt; do command -v "$t" >/dev/null 2>&1 || { echo "FAIL: core tool '$t' absent"; return 1; }; done
}

@test "e2e-happy: 実 bd で remote up-to-date の pull-if-stale は exit 0" {
  _need_real_tools || return 1
  RP="$BATS_TEST_TMPDIR/real"; BARE="$RP/bare"; A="$RP/a"; mkdir -p "$BARE" "$A"
  ( cd "$A" && git init -q && git config user.email t@e.com && git config user.name t && bd init >/dev/null 2>&1 \
    && bd create --title seed >/dev/null 2>&1 && bd dolt remote add origin "file://$BARE" >/dev/null 2>&1 \
    && bd dolt push >/dev/null 2>&1 )
  # 実 bd を使う(BDW_BD_BIN を unset)。throttle 0 で必ず pull。
  run env -u BDW_BD_BIN BDW_LOCK_DIR="$BATS_TEST_TMPDIR/reallocks" BDW_SYNC_THROTTLE_SECS=0 \
      bash -c 'cd "'"$A"'" && "'"$SYNC"'" pull-if-stale'
  ( cd "$A" && bd dolt stop >/dev/null 2>&1 ) || true
  [ "$status" -eq 0 ]
}

@test "e2e-conflict: 実 bd の genuine merge conflict は exit 3(block)" {
  _need_real_tools || return 1
  RP="$BATS_TEST_TMPDIR/rconf"; BARE="$RP/bare"; A="$RP/a"; B="$RP/b"; mkdir -p "$BARE" "$A" "$B/.beads"
  ( cd "$A" && git init -q && git config user.email t@e.com && git config user.name t && bd init >/dev/null 2>&1 \
    && bd create --title seed >/dev/null 2>&1 && bd dolt remote add origin "file://$BARE" >/dev/null 2>&1 \
    && bd dolt push >/dev/null 2>&1 )
  ( cd "$B" && git init -q && git config user.email t@e.com && git config user.name t \
    && printf 'sync:\n  remote: file://%s\n' "$BARE" > .beads/config.yaml && bd bootstrap --yes >/dev/null 2>&1 )
  tid="$( cd "$A" && bd create --title ctgt --json 2>/dev/null | jq -r '.id' )"
  ( cd "$A" && bd dolt push >/dev/null 2>&1 )
  ( cd "$B" && bd dolt pull >/dev/null 2>&1 )
  ( cd "$A" && bd update "$tid" --append-notes A_EDIT >/dev/null 2>&1 && bd dolt push >/dev/null 2>&1 )
  ( cd "$B" && bd update "$tid" --append-notes B_EDIT >/dev/null 2>&1 )
  run env -u BDW_BD_BIN BDW_LOCK_DIR="$BATS_TEST_TMPDIR/rconflocks" BDW_SYNC_THROTTLE_SECS=0 \
      bash -c 'cd "'"$B"'" && "'"$SYNC"'" pull'
  ( cd "$A" && bd dolt stop >/dev/null 2>&1 ) || true
  ( cd "$B" && bd dolt stop >/dev/null 2>&1 ) || true
  [ "$status" -eq 3 ]
  [[ "$output" == *"GENUINE merge conflict"* ]]
}
