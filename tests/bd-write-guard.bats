#!/usr/bin/env bats
# tests/bd-write-guard.bats — universal bd-write-guard の deliverable テスト(un-37xq Leg-B)。
#
# (1) guard の内蔵 --self-test(token battery 50 + 動的 prefix + fail 2 段)を 1 回起動する薄い gate。
# (2) hook e2e: stdin JSON → exit code を hermetic な temp fixture 台帳で pin(rule a/b/c・動的 prefix・
#     dolt push/pull funnel・no-ledger no-op・local-only no-op・fail 2 段)。
# core tool(python3/bats)不在は skip でなく FAIL(契約)。cmdtokens は CMDTOKENS_LIB 供給(不在は BLOCKED 事由にしない)。

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  GUARD="${BDGUARD_OVERRIDE:-$REPO_ROOT/scripts/hooks/bd-write-guard.py}"
  command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 absent (core tool)"; return 1; }
  # cmdtokens 供給: CMDTOKENS_LIB 明示 or plugin 標準配置。
  export CMDTOKENS_LIB="${CMDTOKENS_LIB:-$HOME/.claude/plugins/cmdtokens/lib}"
  [ -f "$CMDTOKENS_LIB/cmdtokens.py" ] || { echo "FAIL: cmdtokens lib 不在: $CMDTOKENS_LIB (CMDTOKENS_LIB で供給せよ)"; return 1; }
}

# hermetic な temp 台帳を作る: dolt_database=<pfx>, remote=有/無。
_mk_ledger() {
  local pfx="$1" remote="$2" d
  d="$BATS_TEST_TMPDIR/led_${pfx}_$RANDOM"; mkdir -p "$d/.beads"
  printf '{"database":"dolt","dolt_database":"%s"}' "$pfx" > "$d/.beads/metadata.json"
  if [ "$remote" = yes ]; then
    printf 'sync.remote: "git+https://example.com/%s.git"\n' "$pfx" > "$d/.beads/config.yaml"
  else
    printf '# local-only\n' > "$d/.beads/config.yaml"
  fi
  printf '%s' "$d"
}

# guard を stdin JSON で叩き exit code を返す。
_guard() {
  local cmd="$1" cwd="$2"
  python3 -c "import json,sys; sys.stdout.write(json.dumps({'tool_input':{'command':'''$cmd'''},'cwd':'''$cwd'''}))" \
    | python3 "$GUARD" >/dev/null 2>&1
}

@test "guard --self-test(token 50 + 動的 prefix + fail 2 段)が exit 0" {
  run python3 "$GUARD" --self-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"token self-test:"*"OK"* ]]
  [[ "$output" == *"dynamic-prefix self-test: OK"* ]]
  [[ "$output" == *"fail2 self-test: OK"* ]]
}

@test "e2e: remote-backed un 台帳の self bare write → deny(2)" {
  L="$(_mk_ledger un yes)"
  run _guard "bd update un-1 --notes x" "$L"
  [ "$status" -eq 2 ]
}

@test "e2e: remote-backed un 台帳の foreign bead write → deny(2)" {
  L="$(_mk_ledger un yes)"
  run _guard "bd update sc-1 --notes x" "$L"
  [ "$status" -eq 2 ]
}

@test "e2e: ★self dolt push/pull → funnel deny(2) / dolt commit → allow(0)" {
  L="$(_mk_ledger un yes)"
  run _guard "bd dolt push" "$L"; [ "$status" -eq 2 ]
  run _guard "bd dolt pull" "$L"; [ "$status" -eq 2 ]
  run _guard "bd dolt commit -m x" "$L"; [ "$status" -eq 0 ]
}

@test "e2e: 動的 prefix — un/sc 台帳で self funnel の対象が入れ替わる(定数移植でない証左)" {
  UN="$(_mk_ledger un yes)"; SC="$(_mk_ledger sc yes)"
  run _guard "bd show un-1" "$UN"; [ "$status" -eq 0 ]
  run _guard "bd show sc-1" "$SC"; [ "$status" -eq 0 ]
  run _guard "bd update un-1" "$UN"; [ "$status" -eq 2 ]   # un session: un self → c
  run _guard "bd update sc-1" "$SC"; [ "$status" -eq 2 ]   # sc session: sc self → c
}

@test "e2e: bdw wrapper は guard を素通し(basename != bd)→ allow(0)" {
  L="$(_mk_ledger un yes)"
  run _guard "bdw update un-1" "$L"; [ "$status" -eq 0 ]
}

@test "e2e: read は allow(0) / echo FP は allow(0)" {
  L="$(_mk_ledger un yes)"
  run _guard "bd show un-1" "$L"; [ "$status" -eq 0 ]
  run _guard "echo bd update un-1" "$L"; [ "$status" -eq 0 ]
}

@test "e2e: local-only(remote 無)台帳 → guard no-op(0)" {
  L="$(_mk_ledger un no)"
  run _guard "bd update un-1 --notes x" "$L"; [ "$status" -eq 0 ]
}

@test "e2e: 台帳外(.beads 皆無)cwd → no-op(0)" {
  d="$BATS_TEST_TMPDIR/noledger_$RANDOM"; mkdir -p "$d"
  run _guard "bd update un-1 --notes x" "$d"; [ "$status" -eq 0 ]
}

@test "e2e-fail2: identity unreadable + remote → fail-closed deny(2)" {
  d="$BATS_TEST_TMPDIR/unreadable_$RANDOM"; mkdir -p "$d/.beads"
  printf '{ not valid json' > "$d/.beads/metadata.json"
  printf 'sync.remote: "git+https://example.com/x.git"\n' > "$d/.beads/config.yaml"
  run _guard "bd update un-1 --notes x" "$d"; [ "$status" -eq 2 ]
}

@test "e2e-fail2: config read 不能(dir 化)→ fail-open(0)" {
  d="$BATS_TEST_TMPDIR/cfgbad_$RANDOM"; mkdir -p "$d/.beads/config.yaml"
  printf '{"database":"dolt","dolt_database":"un"}' > "$d/.beads/metadata.json"
  run _guard "bd update un-1 --notes x" "$d"; [ "$status" -eq 0 ]
}
