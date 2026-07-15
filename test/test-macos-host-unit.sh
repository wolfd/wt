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

echo
echo "== results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
