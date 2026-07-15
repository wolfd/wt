#!/usr/bin/env bash
# Hermetic unit tests for the Mac-side half of macos/: setup-host.sh (this task) and the launch
# agent scripts (appended by the host-agent task). Everything macOS- or Lima-specific is a stub
# on PATH that records its argv, so the suite runs anywhere bash does — including CI's
# ubuntu-latest, where none of the real binaries exist.
set -uo pipefail
while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^WT_' || true)

DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
SETUP="$DIR/../macos/setup-host.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS  $*"; }
no() { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/home" "$T/sdks/MacOSX.sdk"
export LIMACTL_LOG="$T/limactl.log" STATE="$T/state"

# limactl stub: argv-recording, with just enough state that "already exists" is observable —
# `disk create` and `start --name` leave marker files that `disk list` / `list -q` report.
cat > "$T/bin/limactl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LIMACTL_LOG"
case "$1" in
  disk)
    case "$2" in
      list)   [ -e "$STATE/disk" ] && printf 'wtpool    80GiB    /dev/...\n' ;;
      create) touch "$STATE/disk" ;;
    esac ;;
  list)  [ -e "$STATE/vm" ] && printf 'wt\n' ;;
  start) touch "$STATE/vm" ;;
esac
exit 0
STUB
chmod +x "$T/bin/limactl"

run_setup() { env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" \
                  LIMACTL_LOG="$LIMACTL_LOG" STATE="$STATE" "$@" bash "$SETUP"; }

echo "== setup-host.sh: fresh host =="
run_setup WT_MAC_SDKS="$T/sdks" >"$T/out1" 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "fresh run exits 0" || no "fresh run failed (rc=$rc): $(cat "$T/out1")"

[ -d "$T/home/wt-export/incoming" ] && [ -d "$T/home/wt-export/logs/crashes" ] \
  && [ -e "$T/home/wt-export/incoming/run.trigger" ] \
  && ok "the export layout exists (incoming/, logs/crashes/, run.trigger)" \
  || no "export layout missing under $T/home/wt-export"

grep -q '^disk create wtpool --size 80GiB$' "$LIMACTL_LOG" \
  && ok "the wtpool disk is created at the default size" \
  || no "no 'disk create wtpool --size 80GiB': $(grep '^disk' "$LIMACTL_LOG" || echo '<none>')"

start=$(grep -m1 '^start ' "$LIMACTL_LOG" || true)
grep -q -- '--name wt' <<<"$start" && grep -q 'lima\.yaml' <<<"$start" \
  && ok "the VM is started from macos/lima.yaml as instance 'wt'" \
  || no "start line wrong: $start"
grep -q '/wt-src' <<<"$start" && grep -q '/host-sdks' <<<"$start" \
  && ok "--set injects the repo (/wt-src) and SDK (/host-sdks) mounts" \
  || no "mount injection missing from: $start"
grep -qF "$T/sdks" <<<"$start" \
  && ok "the SDK mount honors WT_MAC_SDKS" \
  || no "WT_MAC_SDKS ignored: $start"

echo "== setup-host.sh: idempotent second run =="
run_setup WT_MAC_SDKS="$T/sdks" >"$T/out2" 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "second run exits 0" || no "second run failed (rc=$rc): $(cat "$T/out2")"
[ "$(grep -c '^disk create' "$LIMACTL_LOG")" -eq 1 ] \
  && ok "an existing wtpool disk is not re-created" \
  || no "disk create ran again on the second pass"
grep -q '^start wt$' "$LIMACTL_LOG" \
  && ok "an existing VM is started plainly (no template, no --set)" \
  || no "expected a plain 'start wt' on the second run: $(grep '^start' "$LIMACTL_LOG")"

echo "== setup-host.sh: failure modes name their remedy =="
out=$(env -i PATH="/usr/bin:/bin" HOME="$T/home" bash "$SETUP" 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -qi 'nix profile install' <<<"$out" \
  && ok "missing limactl fails and points at nix" \
  || no "missing limactl: rc=$rc out=$out"
out=$(run_setup WT_MAC_SDKS="$T/empty-sdks" 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -qi 'xcode-select --install' <<<"$out" \
  && ok "a missing MacOSX.sdk fails and points at the Command Line Tools" \
  || no "missing SDK: rc=$rc out=$out"

# ---- host agent ---------------------------------------------------------------------------
RUN="$DIR/../macos/host/run-latest.sh"
AGENT="$DIR/../macos/host/install-agent.sh"
export CALL_LOG="$T/calls.log"

# The macOS binaries, as argv-recording stubs. codesign's verdict and pkill's "found one" are
# both switchable through env, so failure paths are drivable.
for b in xattr codesign open pkill launchctl; do
  cat > "$T/bin/$b" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "$b" "\$*" >> "\$CALL_LOG"
STUB
  chmod +x "$T/bin/$b"
done
cat >> "$T/bin/codesign" <<'STUB'
[ "${CODESIGN_FAIL:-0}" = 1 ] && exit 1
exit 0
STUB
cat >> "$T/bin/pkill" <<'STUB'
exit "${PKILL_FOUND:-1}"
STUB
cat >> "$T/bin/open" <<'STUB'
exit 0
STUB
cat >> "$T/bin/xattr" <<'STUB'
exit 0
STUB
cat >> "$T/bin/launchctl" <<'STUB'
exit 0
STUB

EXP="$T/export"
run_agent() { env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" CALL_LOG="$CALL_LOG" \
                  WT_MAC_EXPORT="$EXP" "$@" bash "$RUN"; }

echo "== run-latest.sh: empty incoming is a no-op =="
: > "$CALL_LOG"; rm -rf "$EXP"; mkdir -p "$EXP/incoming"
run_agent; rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$CALL_LOG" ] \
  && ok "no bundle: exit 0, nothing signed, nothing opened" \
  || no "empty incoming: rc=$rc calls=$(cat "$CALL_LOG")"

echo "== run-latest.sh: the happy path, in order =="
: > "$CALL_LOG"
mkdir -p "$EXP/incoming/Hello.app/Contents/MacOS" "$T/home/Library/Logs/DiagnosticReports"
printf 'binary' > "$EXP/incoming/Hello.app/Contents/MacOS/Hello"
printf 'crash'  > "$T/home/Library/Logs/DiagnosticReports/Hello-2026-07-15.ips"
printf 'other'  > "$T/home/Library/Logs/DiagnosticReports/Else-2026-07-15.ips"
run_agent; rc=$?
[ "$rc" -eq 0 ] && ok "happy path exits 0" || no "happy path rc=$rc: $(cat "$CALL_LOG")"
sign=$(grep -n '^codesign' "$CALL_LOG" | cut -d: -f1 | head -1)
launch=$(grep -n '^open' "$CALL_LOG" | cut -d: -f1 | head -1)
[ -n "$sign" ] && [ -n "$launch" ] && [ "$sign" -lt "$launch" ] \
  && ok "codesign runs before open (never launch an unsigned bundle)" \
  || no "sign/launch order wrong: $(cat "$CALL_LOG")"
grep -q '^open .*--stdout' "$CALL_LOG" \
  && ok "open is wired to the log files (the guest watches them live)" \
  || no "open lost its --stdout wiring: $(grep '^open' "$CALL_LOG")"
[ -e "$EXP/logs/crashes/Hello-2026-07-15.ips" ] && [ ! -e "$EXP/logs/crashes/Else-2026-07-15.ips" ] \
  && ok "crash sweep copies this app's reports only" \
  || no "crash sweep wrong: $(ls "$EXP/logs/crashes" 2>/dev/null)"
[ -e "$EXP/logs/stdout.log" ] && [ -e "$EXP/logs/stderr.log" ] \
  && ok "stdout/stderr logs are (re)created for the new run" \
  || no "log files missing"

echo "== run-latest.sh: newest bundle wins =="
: > "$CALL_LOG"
mkdir -p "$EXP/incoming/Newer.app/Contents/MacOS"
printf 'binary' > "$EXP/incoming/Newer.app/Contents/MacOS/Newer"
touch -t 202601010000 "$EXP/incoming/Hello.app"
run_agent
grep -q '^open .*Newer\.app' "$CALL_LOG" \
  && ok "the most recently shipped bundle is the one launched" \
  || no "expected Newer.app: $(grep '^open' "$CALL_LOG")"

echo "== run-latest.sh: codesign failure aborts before launch =="
: > "$CALL_LOG"
run_agent CODESIGN_FAIL=1; rc=$?
[ "$rc" -ne 0 ] && ! grep -q '^open' "$CALL_LOG" && grep -q 'FAILED' "$EXP/logs/agent.log" \
  && ok "codesign failure: non-zero exit, no launch, logged" \
  || no "codesign failure handled wrong: rc=$rc calls=$(cat "$CALL_LOG")"

echo "== install-agent.sh =="
: > "$CALL_LOG"
env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" CALL_LOG="$CALL_LOG" \
    WT_MAC_EXPORT="$EXP" bash "$AGENT"; rc=$?
PLIST="$T/home/Library/LaunchAgents/dev.wt.mac-runner.plist"
[ "$rc" -eq 0 ] && [ -e "$PLIST" ] \
  && ok "the agent plist is rendered into ~/Library/LaunchAgents" \
  || no "install-agent rc=$rc, plist missing"
# install-agent canonicalizes its own dir (cd/pwd), so match the path's tail, not $DIR/../…
grep -qF "macos/host/run-latest.sh" "$PLIST" && grep -qF "$EXP/incoming/run.trigger" "$PLIST" \
  && ok "the plist points at the real run-latest.sh and the real trigger path" \
  || no "plist has unrendered or wrong paths: $(grep -c '@' "$PLIST") token(s) left"
grep -q '@' "$PLIST" \
  && no "unrendered @TOKENS@ remain in the plist" \
  || ok "every template token was rendered"
grep -q '^launchctl bootstrap gui/' "$CALL_LOG" \
  && ok "the agent is bootstrapped into the gui domain" \
  || no "no launchctl bootstrap call: $(grep '^launchctl' "$CALL_LOG" || echo '<none>')"

echo
echo "== results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
