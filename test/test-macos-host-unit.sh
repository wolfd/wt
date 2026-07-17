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

echo "== setup-host.sh: WT_MAC_SSH_DIR =="
rm -f "$STATE/vm" "$STATE/disk"; : > "$LIMACTL_LOG"
mkdir -p "$T/sshdir"
run_setup WT_MAC_SDKS="$T/sdks" WT_MAC_SSH_DIR="$T/sshdir" >"$T/out3" 2>&1; rc=$?
start=$(grep -m1 '^start ' "$LIMACTL_LOG" || true)
[ "$rc" -eq 0 ] && grep -qF "\"location\": \"$T/sshdir\", \"mountPoint\": \"/host-ssh\", \"writable\": false" <<<"$start" \
  && ok "WT_MAC_SSH_DIR injects a read-only /host-ssh mount on first start" \
  || no "ssh mount missing or not read-only: $start"

rm -f "$STATE/vm" "$STATE/disk"; : > "$LIMACTL_LOG"
run_setup WT_MAC_SDKS="$T/sdks" >"$T/out4" 2>&1
grep -q '/host-ssh' "$LIMACTL_LOG" \
  && no "unset WT_MAC_SSH_DIR still injected /host-ssh" \
  || ok "no knob, no /host-ssh mount"

out=$(run_setup WT_MAC_SDKS="$T/sdks" WT_MAC_SSH_DIR="$T/sshdir" 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'limactl edit' <<<"$out" && grep -qF "$T/sshdir" <<<"$out" \
  && ok "existing VM + knob: succeeds and prints the limactl edit retrofit" \
  || no "no retrofit hint for an existing VM: rc=$rc out=$out"

out=$(run_setup WT_MAC_SDKS="$T/sdks" WT_MAC_SSH_DIR="$T/nope" 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'WT_MAC_SSH_DIR' <<<"$out" \
  && ok "a non-directory WT_MAC_SSH_DIR fails and names the knob" \
  || no "bad ssh dir: rc=$rc out=$out"

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

# ---- vm-git.sh ----------------------------------------------------------------------------
VMGIT="$DIR/../macos/host/vm-git.sh"

# ssh stub: drop "-F <cfg>" and the lima-* host, run the rest locally. Lets the real git run
# against real temp repos, so the stranded-detection logic is genuinely exercised.
cat > "$T/bin/ssh" <<'STUB'
#!/usr/bin/env bash
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -F) shift 2 ;;
    lima-*) shift; args=("$@"); break ;;
    *) shift ;;
  esac
done
exec bash -c "${args[*]}"
STUB
chmod +x "$T/bin/ssh"

# A guest that mirrors the real 2026-07-16 state: one repo with a stranded commit, one whose
# branches all live on a remote-tracking ref despite having no upstream (the false-positive trap).
GD="$T/guest-dev"; mkdir -p "$GD"
gitq() { git -C "$1" -c user.email=t@t -c user.name=t -c init.defaultBranch=main "${@:2}"; }
mkdir -p "$GD/stranded"; git init -q -b main "$GD/stranded"
gitq "$GD/stranded" commit -q --allow-empty -m base
gitq "$GD/stranded" update-ref refs/remotes/origin/main HEAD
gitq "$GD/stranded" commit -q --allow-empty -m "vendor bump"
gitq "$GD/stranded" remote add origin https://example.invalid/stranded

mkdir -p "$GD/safe"; git init -q -b mac-loop "$GD/safe"
gitq "$GD/safe" commit -q --allow-empty -m base
gitq "$GD/safe" update-ref refs/remotes/origin/mac-loop HEAD
gitq "$GD/safe" branch wt/gameplay          # no upstream, but fully on origin/mac-loop
gitq "$GD/safe" remote add origin https://example.invalid/safe

# NAME=VALUE args go to env (the run_setup convention above); the rest are the script's own
# argv. `env -i FOO=1 --survey bash x` would treat --survey as the command and die.
run_vmgit() {
  local envs=()
  while [ $# -gt 0 ] && [ "${1#*=}" != "$1" ]; do envs+=("$1"); shift; done
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" \
      WT_MAC_GUEST_DEV="$GD" LIMACTL_LOG="$LIMACTL_LOG" STATE="$STATE" \
      ${envs[@]+"${envs[@]}"} bash "$VMGIT" "$@"
}

echo "== vm-git.sh: preflight names its remedy =="
mkdir -p "$T/home/.lima/wt"; : > "$T/home/.lima/wt/ssh.config"
out=$(env -i PATH="/usr/bin:/bin" HOME="$T/home" bash "$VMGIT" 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -qi 'nix profile install' <<<"$out" \
  && ok "vm-git: missing limactl fails and points at nix" \
  || no "vm-git: missing limactl: rc=$rc out=$out"

rm -f "$T/home/.lima/wt/ssh.config"
out=$(run_vmgit 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'limactl start wt' <<<"$out" \
  && ok "vm-git: no ssh.config fails and points at 'limactl start wt'" \
  || no "vm-git: missing ssh.config: rc=$rc out=$out"
: > "$T/home/.lima/wt/ssh.config"

echo "== vm-git.sh: the survey is one round-trip of TSV =="
out=$(run_vmgit --survey 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "vm-git: --survey exits 0" || no "vm-git: --survey rc=$rc: $out"
# Literal tabs, not grep -P: this host's grep is BSD and has no -P.
grep -q $'^B\tstranded\tmain\t1\t' <<<"$out" \
  && ok "vm-git: the stranded repo reports 1 commit off all remotes" \
  || no "vm-git: expected 'B stranded main 1': $out"
grep -q $'^B\tsafe\twt/gameplay\t0\t' <<<"$out" \
  && ok "vm-git: an upstream-less branch already on a remote ref counts 0 (no false positive)" \
  || no "vm-git: wt/gameplay must be 0, got: $out"
grep -q $'^U\tsafe\thttps://example.invalid/safe' <<<"$out" \
  && ok "vm-git: the survey reports each repo's origin URL" \
  || no "vm-git: missing U row: $out"
grep -q $'^R\tsafe\torigin/mac-loop\t' <<<"$out" \
  && ok "vm-git: the survey reports remote-tracking refs for the staleness check" \
  || no "vm-git: missing R row: $out"

echo "== vm-git.sh: status =="
# git ls-remote stub, so the staleness cross-check has a controllable "real" remote.
cat > "$T/bin/git" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = ls-remote ] && [ -n "${LSREMOTE_OUT:-}" ]; then cat "$LSREMOTE_OUT"; exit 0; fi
exec /usr/bin/git "$@"
STUB
chmod +x "$T/bin/git"

safe_sha=$(gitq "$GD/safe" rev-parse HEAD)
printf '%s\trefs/heads/mac-loop\n' "$safe_sha" > "$T/lsremote.ok"

out=$(run_vmgit LSREMOTE_OUT="$T/lsremote.ok" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "vm-git: status exits 0 even with stranded work" \
                || no "vm-git: status rc=$rc: $out"
grep -q 'stranded' <<<"$out" && grep -q '1 commit' <<<"$out" \
  && ok "vm-git: status names the stranded repo and its commit count" \
  || no "vm-git: status missed the stranded repo: $out"
grep -q 'safe' <<<"$out" \
  && no "vm-git: status listed a clean repo (must be quiet when clean)" \
  || ok "vm-git: status stays quiet about clean repos"
grep -q 'vm-git.sh fetch' <<<"$out" && grep -q 'refs/vm/stranded/main' <<<"$out" \
  && ok "vm-git: status prints a copy-pasteable fetch/merge recipe" \
  || no "vm-git: no actionable recipe: $out"

echo "== vm-git.sh: status flags a stale remote-tracking cache =="
# refs/heads/main, not mac-loop: only a repo with stranded work reaches the staleness check,
# and that repo is 'stranded', whose cached ref is origin/main. A mac-loop fixture would
# belong to 'safe', never be looked up, and pass by doing nothing.
printf '%s\trefs/heads/main\n' 0000000000000000000000000000000000000000 > "$T/lsremote.stale"
out=$(run_vmgit LSREMOTE_OUT="$T/lsremote.stale" 2>&1)
grep -qi 'stale' <<<"$out" \
  && ok "vm-git: a remote whose sha differs from the cache is flagged stale" \
  || no "vm-git: stale cache not flagged: $out"

echo "== vm-git.sh: fetch =="
HOSTREPO="$T/host-side/boxddd-checkout"   # deliberately NOT named like the guest repo
mkdir -p "$HOSTREPO"; git init -q "$HOSTREPO"
gitq "$HOSTREPO" remote add origin https://example.invalid/stranded   # matches guest 'stranded'

run_fetch() { env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" WT_MAC_GUEST_DEV="$GD" \
                  bash -c "cd '$HOSTREPO' && bash '$VMGIT' fetch $*"; }

out=$(run_fetch 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "vm-git: fetch exits 0" || no "vm-git: fetch rc=$rc: $out"
[ "$(gitq "$HOSTREPO" config --get remote.vm.url)" = "lima-wt:$GD/stranded" ] \
  && ok "vm-git: fetch infers the guest repo from the origin URL, not the directory name" \
  || no "vm-git: wrong vm url: $(gitq "$HOSTREPO" config --get remote.vm.url)"
[ "$(gitq "$HOSTREPO" config --get remote.vm.fetch)" = "+refs/heads/*:refs/vm/stranded/*" ] \
  && ok "vm-git: guest branches land under refs/vm/<project>/* and cannot collide with origin/*" \
  || no "vm-git: wrong refspec: $(gitq "$HOSTREPO" config --get remote.vm.fetch)"
grep -q 'ssh.config' <<<"$(gitq "$HOSTREPO" config --get core.sshCommand)" \
  && ok "vm-git: core.sshCommand is pinned to lima's regenerated config (survives port changes)" \
  || no "vm-git: core.sshCommand not set: $(gitq "$HOSTREPO" config --get core.sshCommand)"
gitq "$HOSTREPO" rev-parse --verify refs/vm/stranded/main >/dev/null 2>&1 \
  && ok "vm-git: the stranded commit actually landed on the host" \
  || no "vm-git: refs/vm/stranded/main missing after fetch"
gitq "$HOSTREPO" rev-parse --verify refs/heads/main >/dev/null 2>&1 \
  && no "vm-git: fetch created a local branch (must only write refs/vm/*)" \
  || ok "vm-git: fetch wrote no local branches"

out=$(run_fetch 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "vm-git: fetch is idempotent (a second run re-uses the vm remote)" \
                || no "vm-git: second fetch failed: $out"

out=$(env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" WT_MAC_GUEST_DEV="$GD" \
      bash -c "cd '$T' && bash '$VMGIT' fetch" 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -qi 'not a git repo' <<<"$out" \
  && ok "vm-git: fetch outside a git repo fails and says so" \
  || no "vm-git: fetch outside a repo: rc=$rc out=$out"

echo "== setup-host.sh points at vm-git.sh =="
out=$(run_setup WT_MAC_SDKS="$T/sdks" 2>&1)
grep -q 'vm-git.sh' <<<"$out" \
  && ok "setup-host closes by naming vm-git.sh (how work gets back out)" \
  || no "setup-host never mentions vm-git.sh: $out"

echo
echo "== results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
