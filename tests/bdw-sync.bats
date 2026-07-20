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
    # FAKE_REMOTE_URL: remote の URL を case 側から差し替える口(既定は file:// を温存=既存 case 不変)。
    # 実 fleet の dolt remote は git+https:// 形式ゆえ scheme 照合の被覆に必須(un-l3ln)。
    if [ "${FAKE_REMOTE:-yes}" = yes ]; then printf 'origin               %s\n' "${FAKE_REMOTE_URL:-file:///fake/bare}"; else echo "No remotes configured."; fi
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

# real e2e が起動した embedded dolt sql-server を **abort 経路でも** 確実に停める安全網。
# bats は test body を set -e 相当で回すため、bare assert が落ちるとその行で test が abort し
# 以降の inline cleanup(`bd dolt stop`)に到達しない → BATS_TEST_TMPDIR 削除後の deleted dir を
# 掴んだ server が残留する。assert 失敗は「テストが検出目的を果たした瞬間」でもあるので、
# 検出成功時にこそ leak するのは規約として整合しない。teardown は成功/失敗/abort に依らず
# 走るためここへ集約する(inline の stop は即時解放として温存・stop は idempotent)。
teardown() {
  for _d in "${A:-}" "${B:-}"; do
    [ -n "$_d" ] && [ -d "$_d" ] && ( cd "$_d" && bd dolt stop >/dev/null 2>&1 ) || true
  done
  return 0
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

# ─── scheme 照合: 複合 scheme(git+https://)の remote を remote 有りと認識する ──────────
# un-l3ln: has_remote の scheme grep が [a-z]+:// だった頃、fleet の実 remote(全て
# git+https://)は "+" に到達できず NO-MATCH → do_pull/do_push が no-op 枝(touch_marker して
# return 0)に常時落ち、一度も実 pull せず marker だけ touch して fresh を偽装していた。
# 既存 case は fake stub が file:///fake/bare(旧 pattern が唯一 MATCH する scheme)を吐くため
# このバグに構造的に盲目だった。ゆえに以下の assert は exit code でなく「CALLS に dolt pull が
# 記録されたか」に置く(bd 不在/stub 未起動でも touch_marker して exit 0 に落ちる fail-open が
# あり、exit 0 だけを見ると vacuous に緑化するため)。
@test "scheme-git-https-pull: git+https:// remote は has_remote=true で実 pull 分岐へ到達する" {
  run env FAKE_REMOTE=yes FAKE_REMOTE_URL="git+https://github.com/shuu5/ubuntu-note-system.git" \
      FAKE_PULL_RC=0 BDW_BD_BIN="$STUB" CALLS="$CALLS" BDW_LOCK_DIR="$BDW_LOCK_DIR" \
      bash -c 'cd "'"$WORK"'" && "'"$SYNC"'" pull'
  [ "$status" -eq 0 ]
  grep -q '^dolt pull$' "$CALLS"            # load-bearing: no-op 枝でなく実 pull へ到達した
}

# do_push も同一 has_remote を共有する(Layer3 pull-push=:219)。1 行修正で Layer1/Layer3 の
# 両経路が回復することを push 側でも pin する。
@test "scheme-git-https-push: git+https:// remote は Layer3 pull-push で push まで到達する" {
  run env FAKE_REMOTE=yes FAKE_REMOTE_URL="git+https://github.com/shuu5/ubuntu-note-system.git" \
      FAKE_PULL_RC=0 FAKE_PUSH_RC=0 BDW_BD_BIN="$STUB" CALLS="$CALLS" BDW_LOCK_DIR="$BDW_LOCK_DIR" \
      bash -c 'cd "'"$WORK"'" && "'"$SYNC"'" pull-push'
  [ "$status" -eq 0 ]
  grep -q '^dolt pull$' "$CALLS"            # Layer1 経路
  grep -q '^dolt push$' "$CALLS"            # Layer3 経路(同一 has_remote 共有)
}

# negative control: scheme 照合を緩めすぎて "No remotes configured." 等を remote 有りと
# 誤認しないこと(⑦ の graceful no-op を壊さない)は invariant7-noremote が担う。
# 追加の over-match 制御として、URL でない行(scheme 無し)を remote 有りと読まないことを pin。
@test "scheme-no-url: scheme を持たない行は remote 有りと誤認しない(over-match 制御)" {
  run env FAKE_REMOTE=yes FAKE_REMOTE_URL="not-a-url-just-text" \
      FAKE_PULL_RC=0 BDW_BD_BIN="$STUB" CALLS="$CALLS" BDW_LOCK_DIR="$BDW_LOCK_DIR" \
      bash -c 'cd "'"$WORK"'" && "'"$SYNC"'" pull'
  [ "$status" -eq 0 ]
  ! grep -q '^dolt pull$' "$CALLS"          # URL でない=remote 無し扱いで no-op
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

# ─── real e2e: 実 bd が吐く git+file:// remote で has_remote=true → 実 pull へ到達 ─────
# un-l3ln の非空虚な real proof。fake stub でなく実 bd の `dolt remote list` 出力
# (= "origin               git+file:///…" の実文言・git+ prefix 保持)に対して scheme 照合が
# 通ることを実測する。fleet の実 remote は git+https:// だが cell は network 遮断ゆえ
# classify が TRANSIENT に degrade する(=判定が濁る)。git+file:// は同じ複合 scheme 形状を
# 保ったまま loopback で完結するため、offline・決定的に real pull を観測できる。
# 実 bd を使いつつ「実 pull へ到達したか」を観測するため、argv を CALLS に記録してから実 bd を
# exec する wrapper を BDW_BD_BIN に差す(挙動は実 bd のまま=canned でない)。exit 0 は no-op 枝
# でも成立する(fail-open)ため、load-bearing assert は CALLS の '^dolt pull$' に置く。
@test "e2e-scheme-git-file: 実 bd の git+file:// remote で実 pull 分岐へ到達する" {
  _need_real_tools || return 1
  RP="$BATS_TEST_TMPDIR/gitfile"; BARE="$RP/bare"; A="$RP/a"; SEED="$RP/seed"; mkdir -p "$A" "$SEED"
  # git+file:// は dolt ネイティブ remote(file://=単なる dir)と違い「git リポジトリ」を指す
  # (mirror-export 経路)。ゆえに bare は実 git repo かつ初期 branch/commit を持つ必要がある
  # (未 seed だと bd が『git remote has no branches』で fetch/push を拒む=実測)。
  git init --bare -q -b main "$BARE"
  ( cd "$SEED" && git init -q -b main && git config user.email t@e.com && git config user.name t \
    && echo seed > README && git add README && git commit -qm init && git push -q "$BARE" main )
  ( cd "$A" && git init -q && git config user.email t@e.com && git config user.name t && bd init >/dev/null 2>&1 \
    && bd create --title seed >/dev/null 2>&1 && bd dolt remote add origin "git+file://$BARE" >/dev/null 2>&1 \
    && bd dolt push >/dev/null 2>&1 )
  # 実 remote list が git+ prefix を保った複合 scheme を吐いていることを直接 pin(前提の実測)。
  run bash -c 'cd "'"$A"'" && bd dolt remote list 2>/dev/null'
  [[ "$output" == *"git+file://"* ]]
  # 記録 wrapper: argv を CALLS に残して実 bd へ委譲する(canned 出力を挟まない)。
  REALBD="$(command -v bd)"
  WRAP="$BATS_TEST_TMPDIR/bd-wrap"
  cat > "$WRAP" <<WRAPEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
exec "$REALBD" "\$@"
WRAPEOF
  chmod +x "$WRAP"
  : >"$CALLS"
  run env BDW_BD_BIN="$WRAP" CALLS="$CALLS" BDW_LOCK_DIR="$BATS_TEST_TMPDIR/gflocks" BDW_SYNC_THROTTLE_SECS=0 \
      bash -c 'cd "'"$A"'" && "'"$SYNC"'" pull-if-stale'
  ( cd "$A" && bd dolt stop >/dev/null 2>&1 ) || true
  [ "$status" -eq 0 ]                       # up-to-date な remote ゆえ OK 分類
  grep -q '^dolt pull$' "$CALLS"            # load-bearing: no-op 枝でなく実 pull を実行した
}

# ═══ un-xywb: resolve_export_root の subdir 台帳誤解決 fix(auto-export root) ═══════════
# bug(ccs-cu9 一次): 独自 .git を持たない subdir 台帳(親 repo の subdir に自前 .beads/embeddeddolt)で
#   旧 resolve_export_root=dirname(git-common-dir) が親 repo root へ誤解決し、auto-export が親の live
#   mirror(例 scribe/.beads/issues.jsonl)を silent 上書きする。fix(walk-up): $PWD..git toplevel で最初に
#   見つかる「物理 DB(embeddeddolt/ / dolt/ / proxieddb/)を持つ .beads」の dir へ収束させる。

# ─── ① 一次検証(dolt 非依存・stub bd): subdir 台帳の auto-export は subdir mirror へ(親でない) ───
# topology(fence i): 親 temp を git init。subdir に .beads/embeddeddolt を作るが subdir では git init
#   しない(subdir に git init するとバグ非発火=vacuous)。親も台帳にして『親 mirror silent 上書き』を再現可能に。
# stub bd(BDW_BD_BIN)が `export -o <path>` を含む argv を CALLS に記録する dolt 非依存方式で、
#   auto-export の効き先を直接 assert する(sandbox で real dolt 不能でも非空虚)。正側 grep で
#   「export が実際に走り subdir を指した」ことを担保(silent skip を負側 assert の根拠にしない)。
@test "export-root-subdir-ledger: subdir 台帳(独自 .git 無し)の auto-export は subdir mirror へ(親でない)" {
  PARENT="$BATS_TEST_TMPDIR/xywb-parent"; SUB="$PARENT/sub"
  mkdir -p "$PARENT" && ( cd "$PARENT" && git init -q && git config user.email t@e.com && git config user.name t )
  mkdir -p "$PARENT/.beads/embeddeddolt" "$SUB/.beads/embeddeddolt"   # 親/subdir 両方が物理 DB 持ち台帳
  # subdir は独自 .git を持たない(親 toplevel)ことを pin(=バグ発火条件・vacuous 化防止)
  run bash -c 'cd "'"$SUB"'" && git rev-parse --show-toplevel'
  [ "$status" -eq 0 ]; [ "$output" != "$SUB" ]
  [ ! -e "$SUB/.git" ]
  expstub="$BATS_TEST_TMPDIR/bd-exp-stub"
  cat > "$expstub" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
case "\$*" in
  "dolt remote list") echo "No remotes configured."; exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
  chmod +x "$expstub"
  : >"$CALLS"
  run env BDW_BD_BIN="$expstub" CALLS="$CALLS" BDW_LOCK_DIR="$BDW_LOCK_DIR" \
      bash -c 'cd "'"$SUB"'" && "'"$BDW"'" update sub-1 --append-notes probe'
  [ "$status" -eq 0 ]
  grep -qF "export -o $SUB/.beads/issues.jsonl" "$CALLS"        # 正側(非空虚): subdir mirror へ効いた
  ! grep -qF "export -o $PARENT/.beads/issues.jsonl" "$CALLS"   # 負側(bug 検出): 親 mirror を上書きしない
}

# ─── ①' 多段上昇 control(dolt 非依存): cwd が台帳 root より深い subdir でも walk-up が上昇して収束 ───
# 看板機構「$PWD..git toplevel の bounded walk-up」の【上昇段(dir="$parent")】そのものの非空虚性を保証する。
# 既存 ① は cwd==台帳 root($SUB)で即 return するため中間 dir を跨ぐ上昇経路を一度も通らない(=上昇段が無検証)。
# realistic modality: worker の cwd が台帳 root より深い subdir(例 scribe/src/foo から bdw を叩き scribe へ収束)。
# topology: 親 = git init(toplevel・親も物理 DB 持ち台帳=誤収束先) / $SUB = 物理 DB 持ち subdir 台帳(真の収束先) /
#   $DEEP = $SUB/deep(.beads 無し=cwd)。walk-up は $DEEP → $SUB へ 1 段上昇して $SUB/.beads/embeddeddolt を発見する。
#   ★上昇段を潰す退行(例 dir="$parent" を dir="$toplevel" に変異=中間 $SUB を skip)ではここで $PARENT へ escape し
#     FAIL する(M14 で機械保証)。既存 ① は $SUB で即 return するため上昇段を skip しても FAIL しない(vacuous だった)。
@test "export-root-subdir-deep: 台帳 root より深い cwd から walk-up が上昇して subdir 台帳 mirror へ収束(親でない)" {
  PARENT="$BATS_TEST_TMPDIR/xywb-deep"; SUB="$PARENT/sub"; DEEP="$SUB/deep"
  mkdir -p "$DEEP" && ( cd "$PARENT" && git init -q && git config user.email t@e.com && git config user.name t )
  mkdir -p "$PARENT/.beads/embeddeddolt" "$SUB/.beads/embeddeddolt"   # 親/subdir 両方が物理 DB 持ち台帳
  [ ! -e "$DEEP/.beads" ]                     # cwd は台帳 root より深く .beads を持たない(=上昇が必要な条件)
  # subdir は独自 .git を持たない(親 toplevel)ことを pin(=バグ発火条件・vacuous 化防止)
  run bash -c 'cd "'"$DEEP"'" && git rev-parse --show-toplevel'
  [ "$status" -eq 0 ]; [ "$output" = "$PARENT" ]   # toplevel=$PARENT(≠$SUB≠$DEEP)。上昇は $DEEP→$SUB の 1 段
  [ ! -e "$SUB/.git" ]
  expstub="$BATS_TEST_TMPDIR/bd-deep-stub"
  cat > "$expstub" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
case "\$*" in
  "dolt remote list") echo "No remotes configured."; exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
  chmod +x "$expstub"
  : >"$CALLS"
  run env BDW_BD_BIN="$expstub" CALLS="$CALLS" BDW_LOCK_DIR="$BDW_LOCK_DIR" \
      bash -c 'cd "'"$DEEP"'" && "'"$BDW"'" update deep-1 --append-notes probe'
  [ "$status" -eq 0 ]
  grep -qF "export -o $SUB/.beads/issues.jsonl" "$CALLS"        # 正側(非空虚): 上昇して subdir 台帳 root へ収束した
  ! grep -qF "export -o $PARENT/.beads/issues.jsonl" "$CALLS"   # 負側(上昇段退行の検出): 親へ over-ascend しない
}

# ─── ② worktree 非回帰 control(dolt 非依存): worktree からの auto-export は anchor へ収束 ────────
# fence(iii). anchor に .beads/embeddeddolt(物理 DB=per-machine) + tracked な .beads/metadata.json を
#   commit。git worktree add で worktree の .beads には metadata.json のみ materialize され embeddeddolt は
#   来ない(物理 DB dir は gitignore 対象=checkout に現れない)。walk-up は空振りし fallback=anchor へ収束する。
#   ★metadata.json を marker にする実装ならここで worktree を誤選択し FAIL する(marker 選定の load-bearing 制御)。
@test "export-root-worktree-noregress: worktree からの auto-export は anchor mirror へ収束(worktree でない)" {
  ANCHOR="$BATS_TEST_TMPDIR/xywb-anchor"
  mkdir -p "$ANCHOR/.beads" && ( cd "$ANCHOR" && git init -q && git config user.email t@e.com && git config user.name t \
      && printf '{}\n' > .beads/metadata.json && git add .beads/metadata.json && git commit -qm beads )
  mkdir -p "$ANCHOR/.beads/embeddeddolt"     # 物理 DB(commit しない=gitignore 相当・per-machine)
  WT="$ANCHOR/wt"
  ( cd "$ANCHOR" && git worktree add -q "$WT" -b xywb-wtbranch >/dev/null 2>&1 )
  [ -f "$WT/.beads/metadata.json" ]          # tracked は materialize される
  [ ! -d "$WT/.beads/embeddeddolt" ]         # 物理 DB dir は materialize されない
  expstub="$BATS_TEST_TMPDIR/bd-wt-stub"
  cat > "$expstub" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
case "\$*" in
  "dolt remote list") echo "No remotes configured."; exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
  chmod +x "$expstub"
  : >"$CALLS"
  run env BDW_BD_BIN="$expstub" CALLS="$CALLS" BDW_LOCK_DIR="$BDW_LOCK_DIR" \
      bash -c 'cd "'"$WT"'" && "'"$BDW"'" update a-1 --append-notes probe'
  [ "$status" -eq 0 ]
  grep -qF "export -o $ANCHOR/.beads/issues.jsonl" "$CALLS"     # anchor へ収束
  ! grep -qF "export -o $WT/.beads/issues.jsonl" "$CALLS"       # worktree へは書かない
}

# ─── ②' 越境ガード control(dolt 非依存): walk-up は git toplevel を越えない(escape 防止) ──────────
# fence/コメント(:140-142)が load-bearing とする破壊防止不変量『walk-up は git toplevel を越えない=
#   git 管理外 / $HOME/.beads への escape を構造的に禁止』の非空虚性を、越境退行を検出する形で機械保証する。
# topology: OUTER(git 管理外・toplevel の親)に物理 DB 持ち .beads を置き、TOP=OUTER/repo を git init して
#   toplevel にする。TOP/.beads は存在するが物理 DB を持たない(=fallback anchor)。cwd=TOP。
#   ・境界が効く実装: dir=TOP は物理 DB 無し→toplevel break→fallback=dirname(common-dir)=TOP へ export。
#   ・境界を外した退行: walk-up が TOP を越えて OUTER/.beads/embeddeddolt を発見し OUTER へ escape する。
#   実バグ相当は「toplevel まで物理 DB 無し + 親側($HOME/.beads 等)に物理 DB 実在」で auto-export が
#   global mirror を silent 上書きする破壊。ここではその親を OUTER として再現し、越境しないことを assert。
#   ★このトポロジは既存 2 case では守られない: subdir-ledger は SUB で即 return し break を通らず、
#     worktree-noregress は break 除去でも WT→ANCHOR で同じ ANCHOR を返し PASS のままだった(M13 で機械保証)。
@test "export-root-boundary-escape: toplevel 越え先(親)に物理 DB があっても越境せず fallback anchor へ収束" {
  BASE="$BATS_TEST_TMPDIR/xywb-boundary"; OUTER="$BASE/outer"; TOP="$OUTER/repo"
  mkdir -p "$TOP/.beads" "$OUTER/.beads/embeddeddolt"      # TOP/.beads=物理 DB 無し / OUTER=物理 DB 持ち(越境先)
  ( cd "$TOP" && git init -q && git config user.email t@e.com && git config user.name t )
  [ ! -d "$TOP/.beads/embeddeddolt" ]        # toplevel は物理 DB を持たない(=boundary break を実際に通る)
  [ -d "$OUTER/.beads/embeddeddolt" ]        # 越境先(親)は物理 DB を持つ(=越境退行時の誤収束先)
  run bash -c 'cd "'"$TOP"'" && git rev-parse --show-toplevel'
  [ "$status" -eq 0 ]; [ "$output" = "$TOP" ]   # boundary=TOP。OUTER は toplevel の外側(git 管理外の親)
  expstub="$BATS_TEST_TMPDIR/bd-boundary-stub"
  cat > "$expstub" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
case "\$*" in
  "dolt remote list") echo "No remotes configured."; exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
  chmod +x "$expstub"
  : >"$CALLS"
  run env BDW_BD_BIN="$expstub" CALLS="$CALLS" BDW_LOCK_DIR="$BDW_LOCK_DIR" \
      bash -c 'cd "'"$TOP"'" && "'"$BDW"'" update b-1 --append-notes probe'
  [ "$status" -eq 0 ]
  grep -qF "export -o $TOP/.beads/issues.jsonl" "$CALLS"       # 正側(非空虚): 境界で停止し fallback anchor(=toplevel)へ
  ! grep -qF "export -o $OUTER/.beads/issues.jsonl" "$CALLS"   # 負側(越境検出): toplevel を越え親の物理 DB へ escape しない
}

# ─── ③ real bd 正側 e2e: 実 bd の subdir 台帳で auto-export が subdir mirror を生成し対象 issue を含む ──
# fence「real bd が temp で動くなら正側 e2e を追加」。実バグトポロジ(ccs-cu9/scribe/cc-session と同型)を
#   real bd で構築: 親 = commit 有 git repo(台帳でない) / sub = bd init で自前 .beads/embeddeddolt(親が
#   台帳でないため bd は sub に local 台帳を作り、独自 .git は作らず親 git を使う=subdir 台帳)。
@test "export-root-subdir-real: 実 bd の subdir 台帳で auto-export が subdir mirror を生成し対象 issue を含む" {
  _need_real_tools || return 1
  RP="$BATS_TEST_TMPDIR/xywb-real"; PARENT="$RP/parent"; SUB="$PARENT/sub"; mkdir -p "$SUB"
  ( cd "$PARENT" && git init -q && git config user.email t@e.com && git config user.name t \
      && printf x > f && git add f && git commit -qm init )
  ( cd "$SUB" && bd init >/dev/null 2>&1 )
  [ -d "$SUB/.beads/embeddeddolt" ]          # sub は物理 DB 持ち台帳
  [ ! -e "$SUB/.git" ]                       # 独自 .git を持たない(=subdir 台帳・親 toplevel)
  run bash -c 'cd "'"$SUB"'" && git rev-parse --show-toplevel'
  [ "$output" != "$SUB" ]
  tid="$( cd "$SUB" && bd create --title realtgt --json 2>/dev/null | jq -r '.id' )"
  [ -n "$tid" ] && [ "$tid" != null ]
  # bdw 自身の auto-export が走ったことを非空虚に示すため、事前に mirror を消してから WRITE する
  rm -f "$SUB/.beads/issues.jsonl"
  run env -u BDW_BD_BIN BDW_LOCK_DIR="$BATS_TEST_TMPDIR/xywb-reallocks" BDW_SYNC_THROTTLE_SECS=0 \
      bash -c 'cd "'"$SUB"'" && "'"$BDW"'" update "'"$tid"'" --append-notes REAL_AE'
  ( cd "$SUB" && bd dolt stop >/dev/null 2>&1 ) || true
  [ "$status" -eq 0 ]
  [ -s "$SUB/.beads/issues.jsonl" ]          # 正側: subdir mirror が生成された
  grep -q "$tid" "$SUB/.beads/issues.jsonl"  # 正側: 対象 issue を含む
  [ ! -e "$PARENT/.beads/issues.jsonl" ]     # 負側: 親(非台帳)には mirror を作らない
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
