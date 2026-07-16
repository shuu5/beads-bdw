#!/usr/bin/env bats
# tests/config-format-pin.bats — has_remote 述語(^sync.remote: col0)の format pin(un-37xq Leg-B)。
#
# tests/fixtures/config-*.yaml(committed)を SSOT にし variant を網羅する(live-fleet scan は非 gating)。
# 述語は bdw_session.has_remote(=guard の has-remote gate が使う実体)。col0 flat `sync.remote: <値>` の
# みを YES とし、indented/commented/nested sync:+remote:/値なし は NO(負例=loud FAIL 相当)。
# 数値: ローカル format 実測母集団(6)と fleet no-op 対象(13)は別概念(混同しない・advisory は rollout un-wjzu)。
#
# core tool(python3/bats)不在は skip でなく FAIL(契約)。

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  LIB="$REPO_ROOT/scripts/hooks/lib"
  FIX="$REPO_ROOT/tests/fixtures"
  command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 absent (core tool)"; return 1; }
}

# fixture の config.yaml を temp .beads に置き has_remote の三値を返すヘルパ(YES/NO/UNKNOWN)。
_has_remote_of() {
  local fixture="$1"
  local d="$BATS_TEST_TMPDIR/l_$RANDOM"; mkdir -p "$d/.beads"
  cp "$FIX/$fixture" "$d/.beads/config.yaml"
  python3 -c "
import sys; sys.path.insert(0,'$LIB')
import bdw_session as s
r=s.has_remote('$d/.beads')
print({s._REMOTE_YES:'YES',s._REMOTE_NO:'NO',s._REMOTE_UNKNOWN:'UNKNOWN'}[r])
"
}

@test "config-remote: col0 flat sync.remote → YES(positive)" {
  run _has_remote_of config-remote.yaml
  [ "$status" -eq 0 ]
  [ "$output" = "YES" ]
}

@test "config-noremote: remote 行皆無(local-only)→ NO(graceful no-op positive)" {
  run _has_remote_of config-noremote.yaml
  [ "$output" = "NO" ]
}

@test "config-indented: 先頭空白付き sync.remote → NO(負例・col0 でない)" {
  run _has_remote_of config-indented.yaml
  [ "$output" = "NO" ]
}

@test "config-commented: # sync.remote → NO(負例・コメント)" {
  run _has_remote_of config-commented.yaml
  [ "$output" = "NO" ]
}

@test "config-nested: nested sync:+remote: → NO(負例・flat でない)" {
  run _has_remote_of config-nested.yaml
  [ "$output" = "NO" ]
}

@test "config.yaml 不在の .beads → NO(remote 未設定と同義)" {
  d="$BATS_TEST_TMPDIR/empty"; mkdir -p "$d/.beads"
  run python3 -c "
import sys; sys.path.insert(0,'$LIB')
import bdw_session as s
r=s.has_remote('$d/.beads')
print({s._REMOTE_YES:'YES',s._REMOTE_NO:'NO',s._REMOTE_UNKNOWN:'UNKNOWN'}[r])
"
  [ "$output" = "NO" ]
}

@test "config.yaml が read 不能(dir 化)→ UNKNOWN(fail-open+loud 側)" {
  d="$BATS_TEST_TMPDIR/badcfg"; mkdir -p "$d/.beads/config.yaml"   # dir 化 → open 失敗
  run python3 -c "
import sys; sys.path.insert(0,'$LIB')
import bdw_session as s
r=s.has_remote('$d/.beads')
print({s._REMOTE_YES:'YES',s._REMOTE_NO:'NO',s._REMOTE_UNKNOWN:'UNKNOWN'}[r])
"
  [ "$output" = "UNKNOWN" ]
}
