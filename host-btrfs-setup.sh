#!/usr/bin/env bash
# host-btrfs-setup.sh — one-time HOST-side provisioning for `wt`'s btrfs-subvolume sandboxes. Run
# it on the HOST (NOT inside the container), as the human who owns the checkout; it re-execs itself
# under sudo for the parts that need root. This is the btrfs counterpart of host-zfs-setup.sh.
#
# It builds exactly what `wt` (WT_BACKEND=btrfs) expects to already be there, and nothing else:
#   WT_CANONICAL         the checkout, turned into a btrfs SUBVOLUME (btrfs can only snapshot a
#                        subvolume, never a plain directory). If it is currently a plain directory,
#                        its contents are migrated INTO the new subvolume, in place.
#   WT_CANONICAL/<sub>   one NESTED subvolume per WT_SNAPSHOT_EXCLUDE entry. `wt new` snapshots
#                        WT_CANONICAL non-recursively, so a nested subvolume snapshots as an empty
#                        stub — the mechanism that keeps a subpath out of every sandbox. wt-setup.sh
#                        then bind-mounts the canonical copy back in, so all sandboxes share one.
#   WT_BTRFS_PARENT      a plain directory (same btrfs filesystem as WT_CANONICAL) the per-sandbox
#                        subvolumes hang under. Its path is also a sensible home for wt's state dir.
#   sudoers rule         a scoped NOPASSWD grant for `btrfs subvolume snapshot|delete`, because
#                        btrfs has NO `zfs allow` delegation — the only way to let an unprivileged
#                        user snapshot/delete a subvolume is to grant it root for those commands.
#
#   >>> SECURITY: that sudoers rule is a STANDING passwordless-root grant. It is scoped as tightly
#   >>> as possible — one user, exactly `btrfs subvolume snapshot|delete`, only under WT_BTRFS_PARENT
#   >>> (and snapshot only FROM WT_CANONICAL) — but any process running as that user can create or
#   >>> delete subvolumes under that parent. This script prints the exact rule and asks before
#   >>> installing it. Read it. If that grant is not acceptable, do not use the btrfs backend.
#
# Config is read the way `wt` reads it: $WT_CONFIG, else ~/.config/wt/config, else /etc/wt/config,
# with the environment overriding the file. In the common distrobox case WT_CANONICAL is the same
# path on host and in the box (the home bind), so no path argument is needed.
#
# Safe to re-run: every subvolume/dir/sudoers step is skipped if it is already in place.
# It checks the WHOLE plan first, prints it, and asks once before moving any data.
#
# Usage: host-btrfs-setup.sh [CHECKOUT_DIR [PARENT_DIR]] [-y]
#   CHECKOUT_DIR   the checkout to make a subvolume        (default: $WT_CANONICAL from config)
#   PARENT_DIR     directory the sandbox subvolumes hang under (default: $WT_BTRFS_PARENT from config)
#   -y, --yes      don't prompt before migrating a plain-directory checkout or installing sudoers
set -euo pipefail

die() { echo "host-btrfs-setup: $*" >&2; exit 1; }
log() { echo "host-btrfs-setup: $*" >&2; }
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"; }

# This must run on the host: creating a subvolume needs CAP_SYS_ADMIN in the userns that OWNS the
# filesystem, which a rootless container does not have, and the sudoers rule belongs to the host.
if [ -e /run/.containerenv ] || [ -e /run/.toolboxenv ]; then
  die "this is running inside a container — run it on the HOST (subvolume create and the sudoers rule are host-side)"
fi

# Root for subvolume create/delete, chown, and writing /etc/sudoers.d. -E so a WT_* override
# (WT_CONFIG above all) set by the caller survives into the root pass.
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E "$0" "$@"
fi

assume_yes=0
args=()
for a in "$@"; do
  case "$a" in
    -y|--yes)  assume_yes=1 ;;
    -h|--help) usage; exit 0 ;;
    -*)        die "unknown option '$a' (try --help)" ;;
    *)         args+=("$a") ;;
  esac
done

# ---- config -------------------------------------------------------------------------------
# The invoking human, not root: past the sudo re-exec, $HOME is root's. Their uid is also the
# identity the sandboxes run as, and the user the sudoers rule is written for.
ORIG_USER=${SUDO_USER:-$(id -nu)}
ORIG_HOME=$(getent passwd "$ORIG_USER" | cut -d: -f6)
[ -n "$ORIG_HOME" ] || die "could not determine the home directory of '$ORIG_USER'"

# Precedence and search order are `wt`'s, idiom for idiom, so the two cannot drift.
_wt_env=$(export -p | grep -E '^declare -x WT_[A-Za-z0-9_]+=' || true)
if [ -z "${WT_CONFIG+x}" ]; then
  for _c in "${XDG_CONFIG_HOME:-$ORIG_HOME/.config}/wt/config" /etc/wt/config; do
    [ -r "$_c" ] && { WT_CONFIG=$_c; break; }
  done
fi
if [ -n "${WT_CONFIG:-}" ]; then
  [ -r "$WT_CONFIG" ] || die "config file not readable: $WT_CONFIG"
  # shellcheck source=/dev/null
  . "$WT_CONFIG"
  eval "$_wt_env"        # environment wins over the file
fi

WT_CANONICAL=${WT_CANONICAL:-}
WT_BTRFS_PARENT=${WT_BTRFS_PARENT:-}
WT_SNAPSHOT_EXCLUDE=${WT_SNAPSHOT_EXCLUDE:-}
WT_TARGET_UID=${WT_TARGET_UID:-$(id -u "$ORIG_USER")}
WT_TARGET_GID=${WT_TARGET_GID:-$(id -g "$ORIG_USER")}
WT_TARGET_USER=${WT_TARGET_USER:-}

CHECKOUT_DIR=${args[0]:-$WT_CANONICAL}
[ -n "$CHECKOUT_DIR" ] \
  || die "no checkout path: pass one as the first argument, or set WT_CANONICAL (config: ${WT_CONFIG:-none found})"
case "$CHECKOUT_DIR" in /*) ;; *) die "checkout path must be absolute: $CHECKOUT_DIR" ;; esac
CHECKOUT_DIR=${CHECKOUT_DIR%/}
# host-btrfs-setup makes WT_CANONICAL itself the source subvolume, so the two are the same path
# here (unlike the zfs devcontainer split). Keep WT_CANONICAL pointing at the same place so the
# subvolume/exclude checks below read the right tree.
WT_CANONICAL=$CHECKOUT_DIR

PARENT_DIR=${args[1]:-$WT_BTRFS_PARENT}
[ -n "$PARENT_DIR" ] \
  || die "no sandbox-parent path: pass one as the second argument, or set WT_BTRFS_PARENT (config: ${WT_CONFIG:-none found})"
case "$PARENT_DIR" in /*) ;; *) die "WT_BTRFS_PARENT must be absolute: $PARENT_DIR" ;; esac
PARENT_DIR=${PARENT_DIR%/}
WT_BTRFS_PARENT=$PARENT_DIR

# Disjoint, both directions — `wt` refuses the same layouts, for the same reason: `wt gc` destroys
# the children of WT_BTRFS_PARENT and enumerates subvolumes relative to WT_CANONICAL. Nest either
# inside the other and a destroy loop is pointed at live data (the exclude subvols, or the source).
case "$WT_BTRFS_PARENT" in
  "$WT_CANONICAL"|"$WT_CANONICAL"/*) die "WT_BTRFS_PARENT must not be, or live under, WT_CANONICAL ($WT_CANONICAL)" ;;
esac
case "$WT_CANONICAL" in
  "$WT_BTRFS_PARENT"/*) die "WT_CANONICAL must not live under WT_BTRFS_PARENT ($WT_BTRFS_PARENT)" ;;
esac

# ---- identity for the sudoers rule --------------------------------------------------------
# The rule is written for whichever HOST account has WT_TARGET_UID — the box's user maps to that
# uid over the home bind, whatever the container calls it. Refuse root, and refuse a name/uid clash.
[ "$WT_TARGET_UID" != 0 ] \
  || die "WT_TARGET_UID resolved to 0 — sandboxes must not run as root; set WT_TARGET_UID in the config"
if [ -n "$WT_TARGET_USER" ] && getent passwd "$WT_TARGET_USER" >/dev/null 2>&1; then
  _u=$(id -u "$WT_TARGET_USER")
  [ "$_u" = "$WT_TARGET_UID" ] \
    || die "host user '$WT_TARGET_USER' is uid $_u but WT_TARGET_UID=$WT_TARGET_UID — the sudoers rule would name the wrong identity"
fi
HOST_USER=$(getent passwd "$WT_TARGET_UID" | cut -d: -f1 || true)
[ -n "$HOST_USER" ] \
  || die "no host account has uid $WT_TARGET_UID — a sudoers rule needs a real host user; create one, or set WT_TARGET_UID to an existing host uid"

# ---- sanity -------------------------------------------------------------------------------
command -v btrfs >/dev/null 2>&1 || die "btrfs CLI not found on this host (install btrfs-progs)"
command -v rsync >/dev/null 2>&1 || die "rsync not found — it is what moves your content into the new subvolumes"
command -v visudo >/dev/null 2>&1 || die "visudo not found — needed to validate the sudoers rule before installing it"
BTRFS_BIN=$(command -v btrfs)

fs_device_of() { findmnt -no SOURCE --target "$1" 2>/dev/null | sed 's/\[.*//' | head -1; }
fs_type_of()   { findmnt -no FSTYPE --target "$1" 2>/dev/null | head -1; }
nearest_existing() { local p=$1; while [ ! -e "$p" ] && [ "$p" != / ]; do p=$(dirname -- "$p"); done; printf '%s' "$p"; }

_canon_probe=$(nearest_existing "$CHECKOUT_DIR")
[ "$(fs_type_of "$_canon_probe")" = btrfs ] \
  || die "$CHECKOUT_DIR is not on a btrfs filesystem (found '$(fs_type_of "$_canon_probe")') — the btrfs backend needs btrfs"
# Snapshots cannot cross filesystems: the sandbox parent must be on the SAME btrfs fs as the source.
_parent_probe=$(nearest_existing "$WT_BTRFS_PARENT")
[ "$(fs_device_of "$_canon_probe")" = "$(fs_device_of "$_parent_probe")" ] \
  || die "WT_BTRFS_PARENT ($WT_BTRFS_PARENT) is on a different filesystem than WT_CANONICAL — btrfs snapshots cannot cross filesystems. Put both on the same btrfs fs."

log "config        : ${WT_CONFIG:-none found (env only)}"
log "checkout      : $CHECKOUT_DIR   (becomes a btrfs subvolume)"
log "sandbox parent: $WT_BTRFS_PARENT"
log "never snapshot: ${WT_SNAPSHOT_EXCLUDE:-<none>}"
log "sudoers for   : $HOST_USER (uid $WT_TARGET_UID)"

# ---- helpers ------------------------------------------------------------------------------
confirm() {
  [ "$assume_yes" -eq 1 ] && return 0
  [ -t 0 ] || die "$1 — refusing to do that non-interactively; re-run with -y if it is what you want"
  local a
  read -r -p "host-btrfs-setup: $1 [y/N] " a || true
  case "$a" in y|Y|yes|YES) return 0 ;; *) die "aborted" ;; esac
}

# A btrfs subvolume root always has inode 256 — the cheap, unprivileged "is this a subvolume?" test.
is_subvol() { [ "$(stat -c %i "$1" 2>/dev/null)" = 256 ]; }

is_mountpoint() {
  local d=$1 real
  [ -d "$d" ] || return 1
  real=$(realpath -s -- "$d" 2>/dev/null) || return 1
  [ "$(findmnt -rn --target "$real" -o TARGET 2>/dev/null | head -1)" = "$real" ]
}

# Cheap post-copy proof that nothing was dropped. Exact for a subtree we copied whole.
verify_identical() {
  local src=$1 dst=$2 src_n dst_n src_b dst_b
  src_n=$(find "$src" -mindepth 1 | wc -l); dst_n=$(find "$dst" -mindepth 1 | wc -l)
  src_b=$(du -sb "$src" | cut -f1);         dst_b=$(du -sb "$dst" | cut -f1)
  log "  verify $src: src files=$src_n bytes=$src_b ; dst files=$dst_n bytes=$dst_b"
  if [ "$src_n" != "$dst_n" ] || [ "$src_b" != "$dst_b" ]; then
    die "copy verify FAILED for $src (file count or size differs); nothing was deleted — the original is intact at $src"
  fi
}

# Everything that must be TRUE before we turn a directory into a subvolume. Run in preflight, so
# the script can refuse while the world is still exactly as the user left it.
check_promotable() {
  local dir=$1
  is_subvol "$dir" && return 0        # already a subvolume: nothing to do
  [ -e "$dir" ] || return 0           # nothing there: a plain create
  [ -d "$dir" ] || die "$dir exists but is not a directory"
  ! is_mountpoint "$dir" \
    || die "$dir is a mountpoint, not a plain directory — unmount it first, or point this elsewhere"
  [ -w "$(dirname -- "$dir")" ] \
    || die "$(dirname -- "$dir") is not writable — cannot rename $dir aside to make room for a subvolume"
  [ ! -e "$dir.aside.$$" ] || die "$dir.aside.$$ already exists; move it away first"
}

# Shape of one WT_SNAPSHOT_EXCLUDE entry. Unlike zfs, btrfs needs no intermediate subvolume for a
# nested entry: `btrfs subvolume create a/b/c` only needs a/b to be a directory, and a/b stays a
# plain (snapshotted) directory. So only the subpath shape is checked here.
check_exclude_entry() {
  case "$1" in
    /*|*/|*//*|*..*) die "WT_SNAPSHOT_EXCLUDE entry '$1' must be a plain relative subpath (no leading/trailing slash, no ..)" ;;
  esac
}

# Turn an existing plain directory into a subvolume without losing what is in it. RENAME aside in a
# single rename(2) (no half-moved state), create the subvolume over the freed path, copy the content
# back, verify. If the create fails, the rename is undone. The aside copy is NEVER deleted — it is
# the rollback, and reclaiming it is the user's decision to make once they have looked.
promote_dir_to_subvol() {
  local dir=$1
  if is_subvol "$dir"; then log "$dir is already a subvolume; skipping"; return 0; fi
  local staged=""
  if [ -d "$dir" ]; then
    if [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
      staged="$dir.aside.$$"
      log "renaming $dir -> $staged (one rename; your rollback copy, and it is not deleted)"
      mv -T -- "$dir" "$staged" || die "could not rename $dir aside — nothing was changed"
    else
      rmdir -- "$dir" || die "could not rmdir the empty $dir — nothing was changed"
    fi
  fi
  if ! btrfs subvolume create "$dir" >/dev/null; then
    [ -n "$staged" ] && { mv -T -- "$staged" "$dir" && log "rolled back: $dir is exactly as it was"; }
    die "btrfs subvolume create $dir failed"
  fi
  chown "$WT_TARGET_UID:$WT_TARGET_GID" "$dir"
  if [ -n "$staged" ]; then
    log "copying $staged/ into the new subvolume at $dir/"
    rsync -aHAX "$staged"/ "$dir"/ || die "copy into $dir failed — your data is untouched at $staged"
    verify_identical "$staged" "$dir"
    log "$dir is now a subvolume. The pre-migration copy is at $staged; remove it when satisfied: rm -rf $staged"
  fi
  log "created subvolume $dir"
}
create_exclude_subvol() { promote_dir_to_subvol "$WT_CANONICAL/$1"; }

# ---- preflight ----------------------------------------------------------------------------
# Every check, before every action. The one job that can fail destructively is migrating the
# checkout, so decide up front whether the whole plan can succeed and refuse while nothing is moved.
ASIDE_DIR=$CHECKOUT_DIR.aside
plan=()
PLAN_MIGRATE=0

if is_subvol "$CHECKOUT_DIR"; then
  plan+=( "$CHECKOUT_DIR is already a subvolume — no checkout migration" )
elif [ ! -e "$CHECKOUT_DIR" ]; then
  plan+=( "create empty subvolume $CHECKOUT_DIR (clone your repo into it afterwards)" )
else
  [ -d "$CHECKOUT_DIR" ] || die "$CHECKOUT_DIR exists but is not a directory"
  ! is_mountpoint "$CHECKOUT_DIR" \
    || die "$CHECKOUT_DIR is a mountpoint, not a plain directory — unmount it, or point WT_CANONICAL at a subvolume that already exists"
  [ ! -e "$ASIDE_DIR" ] \
    || die "$ASIDE_DIR already exists; refusing to overwrite it — move or remove it first"
  [ -w "$(dirname -- "$CHECKOUT_DIR")" ] \
    || die "$(dirname -- "$CHECKOUT_DIR") is not writable — cannot move the checkout aside"
  PLAN_MIGRATE=1
  plan+=( "move $CHECKOUT_DIR -> $ASIDE_DIR, create subvolume there, copy the content back" )
fi

for sub in $WT_SNAPSHOT_EXCLUDE; do
  check_exclude_entry "$sub"
  check_promotable "$CHECKOUT_DIR/$sub"
  is_subvol "$CHECKOUT_DIR/$sub" \
    || plan+=( "create nested subvolume $CHECKOUT_DIR/$sub (never snapshotted; shared by every sandbox)" )
done

[ -d "$WT_BTRFS_PARENT" ] \
  || plan+=( "create directory $WT_BTRFS_PARENT (the per-sandbox subvolumes hang under it)" )

SUDOERS_ALIAS="WT_BTRFS_${WT_TARGET_UID}"
SUDOERS_FILE="/etc/sudoers.d/wt-btrfs-${HOST_USER}"
SUDOERS_RULE="# wt btrfs backend — installed by host-btrfs-setup.sh. A STANDING passwordless-root grant,
# scoped to exactly \`btrfs subvolume snapshot|delete\` on the sandbox paths below. Review before trusting.
Cmnd_Alias ${SUDOERS_ALIAS} = ${BTRFS_BIN} subvolume snapshot ${WT_CANONICAL} ${WT_BTRFS_PARENT}/*, ${BTRFS_BIN} subvolume delete ${WT_BTRFS_PARENT}/*
${HOST_USER} ALL=(root) NOPASSWD: ${SUDOERS_ALIAS}"
plan+=( "install NOPASSWD sudoers rule at $SUDOERS_FILE (snapshot|delete for $HOST_USER — see below)" )

log "plan:"
for p in "${plan[@]}"; do log "  - $p"; done
if [ "$PLAN_MIGRATE" -eq 1 ]; then
  confirm "this moves your checkout at $CHECKOUT_DIR. Nothing is deleted — $ASIDE_DIR is kept as your rollback. Proceed?"
fi

# ---- the source subvolume -----------------------------------------------------------------
migrated=0
if [ "$PLAN_MIGRATE" -eq 1 ]; then
  log "mv $CHECKOUT_DIR -> $ASIDE_DIR (one rename; nothing deleted, this is your rollback copy)"
  mv -T -- "$CHECKOUT_DIR" "$ASIDE_DIR"
  log "btrfs subvolume create $CHECKOUT_DIR"
  if ! btrfs subvolume create "$CHECKOUT_DIR" >/dev/null; then
    mv -T -- "$ASIDE_DIR" "$CHECKOUT_DIR" && log "rolled back: $CHECKOUT_DIR is exactly as it was"
    die "btrfs subvolume create $CHECKOUT_DIR failed"
  fi
  chown "$WT_TARGET_UID:$WT_TARGET_GID" "$CHECKOUT_DIR"
  migrated=1
elif [ ! -e "$CHECKOUT_DIR" ]; then
  log "creating empty subvolume $CHECKOUT_DIR (nothing there yet — clone your repo into it afterwards)"
  btrfs subvolume create "$CHECKOUT_DIR" >/dev/null
  chown "$WT_TARGET_UID:$WT_TARGET_GID" "$CHECKOUT_DIR"
fi

# ---- the never-snapshotted nested subvolumes ----------------------------------------------
# Created BEFORE any refill: an excluded subpath's data must land IN its own subvolume, or a
# snapshot would faithfully capture it. When migrating, the source is freshly empty, so each of
# these is a plain create; the refill below fills them from the aside.
for sub in $WT_SNAPSHOT_EXCLUDE; do
  create_exclude_subvol "$sub"
done

# ---- refill the checkout from the aside ---------------------------------------------------
if [ "$migrated" -eq 1 ]; then
  # Excluded subpaths first, each into its own nested subvolume, verified exactly — this is the
  # data that lives in ONE place and is shared by every sandbox, so a silent short copy here is
  # unrecoverable once the aside is reclaimed.
  for sub in $WT_SNAPSHOT_EXCLUDE; do
    [ -d "$ASIDE_DIR/$sub" ] || continue
    log "rsync $sub/ -> $CHECKOUT_DIR/$sub (own subvolume; never snapshotted)"
    rsync -aHAX --info=progress2 "$ASIDE_DIR/$sub/" "$CHECKOUT_DIR/$sub/"
    verify_identical "$ASIDE_DIR/$sub" "$CHECKOUT_DIR/$sub"
  done

  rsync_excl=(); du_excl=()
  for sub in $WT_SNAPSHOT_EXCLUDE; do
    rsync_excl+=( --exclude="/$sub/" )
    du_excl+=( --exclude="$sub" )
  done
  log "rsync the rest of the checkout -> $CHECKOUT_DIR"
  rsync -aHAX --info=progress2 ${rsync_excl[@]+"${rsync_excl[@]}"} "$ASIDE_DIR/" "$CHECKOUT_DIR/"

  src_b=$(du -sb ${du_excl[@]+"${du_excl[@]}"} "$ASIDE_DIR"    | cut -f1)
  dst_b=$(du -sb ${du_excl[@]+"${du_excl[@]}"} "$CHECKOUT_DIR" | cut -f1)
  drift=$(( src_b > dst_b ? src_b - dst_b : dst_b - src_b ))
  log "  verify source: src bytes=$src_b ; dst bytes=$dst_b ; drift=$drift"
  if [ "$drift" -ge 104857600 ]; then    # 100 MiB — larger than any plausible per-directory drift
    die "source rsync verify FAILED (drift $drift bytes); nothing was deleted — the original is intact at $ASIDE_DIR"
  fi
fi

# ---- the sandbox parent directory ---------------------------------------------------------
if [ ! -d "$WT_BTRFS_PARENT" ]; then
  log "mkdir $WT_BTRFS_PARENT (per-sandbox subvolumes hang under it)"
  mkdir -p "$WT_BTRFS_PARENT"
  chown "$WT_TARGET_UID:$WT_TARGET_GID" "$WT_BTRFS_PARENT"
fi

# ---- the sudoers rule ---------------------------------------------------------------------
# btrfs has no `zfs allow`, so this is how `wt new`/`wt rm` reach root for snapshot/delete without a
# password. Scoped as tightly as sudoers allows: one user, exactly the two verbs, snapshot only FROM
# WT_CANONICAL, both bounded to direct children of WT_BTRFS_PARENT (the `*` wildcard does not cross
# '/'). It is still a real passwordless-root grant — see the header warning.
log ""
log "About to install this sudoers rule at $SUDOERS_FILE:"
printf '%s\n' "$SUDOERS_RULE" | sed 's/^/    /' >&2
log ""
if [ -f "$SUDOERS_FILE" ] && [ "$(cat "$SUDOERS_FILE")" = "$SUDOERS_RULE" ]; then
  log "sudoers rule already present and identical; leaving it in place"
else
  confirm "install the passwordless-root sudoers rule above for $HOST_USER?"
  _tmp=$(mktemp)
  printf '%s\n' "$SUDOERS_RULE" > "$_tmp"
  chmod 0440 "$_tmp"
  visudo -cf "$_tmp" >/dev/null || { rm -f "$_tmp"; die "the generated sudoers rule failed validation (visudo -c) — NOT installed"; }
  install -m 0440 -o root -g root "$_tmp" "$SUDOERS_FILE"
  rm -f "$_tmp"
  log "installed $SUDOERS_FILE"
fi

# ---- probe --------------------------------------------------------------------------------
# Prove the grant actually works for that identity, doing exactly what `wt new`/`wt rm` do on the
# host: as the target user, `sudo -n btrfs subvolume snapshot|delete` (the -n asserts NO password
# prompt). The outer `sudo -u` drops root to the user; the inner `sudo -n` exercises the new rule.
probe_dst="$WT_BTRFS_PARENT/wt-host-setup-probe-$$"
log "probing: sudo -u $HOST_USER sudo -n btrfs subvolume snapshot $WT_CANONICAL $probe_dst"
if sudo -u "$HOST_USER" sudo -n "$BTRFS_BIN" subvolume snapshot "$WT_CANONICAL" "$probe_dst" >/dev/null 2>"$probe_dst.err"; then
  sudo -u "$HOST_USER" sudo -n "$BTRFS_BIN" subvolume delete "$probe_dst" >/dev/null 2>>"$probe_dst.err" \
    || die "probe snapshot was created but $HOST_USER could not delete it — delete $probe_dst by hand and re-check the sudoers rule"
  rm -f "$probe_dst.err"
  log "OK: $HOST_USER can snapshot and delete under $WT_BTRFS_PARENT with no password"
else
  log "probe stderr: $(head -1 "$probe_dst.err" 2>/dev/null)"
  rm -f "$probe_dst.err"
  die "probe FAILED: $HOST_USER cannot snapshot despite the sudoers rule — inspect $SUDOERS_FILE and 'sudo -l -U $HOST_USER'"
fi

# ---- done ---------------------------------------------------------------------------------
log ""
log "Host setup complete. Next:"
log "  * In your config set WT_BACKEND=btrfs, WT_CANONICAL=$CHECKOUT_DIR, WT_BTRFS_PARENT=$WT_BTRFS_PARENT."
log "  * From INSIDE the box, run 'wt status' — it should show backend btrfs and 'src subvol ok : yes'."
log "  * Then 'wt new probe && wt enter probe -- true && wt rm probe' to exercise the round-trip."
if [ "$migrated" -eq 1 ]; then
  log "  * Verify $CHECKOUT_DIR looks right (git status; build it), then reclaim the copy:"
  log "       rm -rf $ASIDE_DIR"
  log ""
  log "Rollback — only before that rm, and only if something looks wrong:"
  log "  btrfs subvolume delete $CHECKOUT_DIR/<each exclude>   # if any were created"
  log "  btrfs subvolume delete $CHECKOUT_DIR"
  log "  mv $ASIDE_DIR $CHECKOUT_DIR"
fi
