#!/usr/bin/env bash
# lab-helpers/gpu-real/nvidia-docker-runtime.sh
#
# Purpose: switch THIS machine's Docker into the configuration nvkind needs
# to give a kind worker node a real GPU, and switch it back. This is the only
# script in the repo that uses sudo or writes under /etc; the Makefile never
# calls it (`make up PROFILE=gpu-real` only checks `status`). It is
# kind-specific host setup for tutorial chapters 17-18, not something a real
# cluster node needs.
#
# While enabled, these effects are host-wide, not limited to kind:
#   - Docker's default runtime is nvidia: every container created without an
#     explicit --runtime starts through nvidia-container-runtime, not runc.
#   - accept-nvidia-visible-devices-as-volume-mounts = true: a bind mount at
#     /var/run/nvidia-container-devices/<index|all> is read as a GPU request,
#     with no --gpus or --runtime flag needed. Source: nvidia-container-toolkit
#     internal/config/image/cuda_image.go (main, read 2026-11-08).
#   - CDI is enabled in dockerd (features.cdi), and dockerd is restarted.
#
# Session order:
#   nvidia-docker-runtime.sh enable
#   make up PROFILE=gpu-real
#   ... work ...
#   make down PROFILE=gpu-real
#   nvidia-docker-runtime.sh disable
#   (when finished with the GPU chapters) make clean PROFILE=gpu-real
#
# The commands in `enable` are the ones in the nvkind README, section "Setup"
# (https://github.com/NVIDIA/nvkind/blob/c57050497cffee36f10c8b918d2727c4f26d886e/README.md,
# read 2026-11-08), with one change: the config.toml command gets an explicit
# --config-file, so the file edited is always the file backed up ($NVIDIA_CONFIG)
# and the dry-run (which runs nvidia-ctk as you, on a temp copy) can point it at
# that copy. Run as a normal user, nvidia-ctk's default is a per-user file.
#
# Recovery: `disable` works with Docker stopped or broken. It treats an
# unreachable daemon as "no running containers, no cluster", restores the
# files, starts Docker, then verifies. `enable` prints that command if it fails
# after it has started changing files.
#
# Verification: before changing anything, `enable` records a sha256 of every
# file under /etc/docker, /etc/nvidia-container-runtime and /etc/cdi (or that
# the directory did not exist). `disable` recomputes the record after the
# restore and requires an exact match.
#
# Run it in a normal terminal as your own user; it calls sudo itself.
set -euo pipefail

PROG=$(basename "$0")
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$PROG
DAEMON_JSON=/etc/docker/daemon.json
NVIDIA_CONFIG=/etc/nvidia-container-runtime/config.toml
BACKUP_DIR=/var/backups/k8s-lab-gpu-real
CLUSTER_NAME=k8s-lab-gpu-real
KEY=accept-nvidia-visible-devices-as-volume-mounts
VERIFY_DIRS=(/etc/docker /etc/nvidia-container-runtime /etc/cdi)
# Every file enable writes into $BACKUP_DIR; disable removes exactly these, then rmdir.
BACKUP_FILES=(daemon.json daemon.json.absent config.toml default-runtime manifest.sha256 COMPLETE)

DRY_RUN=0
TMP=
PARTIAL=0   # 1 once enable has started writing the backup
RECOVER=0   # 1 once enable's backup is complete and files may change

usage() {
  cat <<EOF
Usage: $PROG [-n|--dry-run] status|enable|disable
       $PROG -h|--help

Subcommands:
  status   Read-only. Docker's default runtime, whether a backup and a
           verification record exist, the relevant keys in both files, running
           containers. Exit 0 if enabled, 1 otherwise.
  enable   Back up both files, record sha256 of every file under the verify
           dirs, set nvidia as Docker's default runtime with CDI, set
           $KEY=true, restart docker, verify.
           Exit 0 without changes if already enabled. Refuses if any
           container is running, if docker is unreachable, or if a backup from
           an earlier run exists. If it fails after changing files it prints
           the command to restore: $PROG disable.
  disable  Restore both files from the backup, restart (or start) docker,
           verify with cmp, the default runtime and the sha256 record, then
           remove the backup. Exit 0 without changes if already disabled.
           Refuses if any container is running or the $CLUSTER_NAME
           cluster exists; an unreachable docker counts as neither, so it works
           with docker down. On any failed check it keeps the backup, reports
           added/removed/changed files, and exits 1. If the backup dir holds
           anything this script did not write, it deletes nothing, lists those
           entries, and exits 1.

Options:
  -n, --dry-run  enable/disable only: print each command instead of running
                 it, plus a unified diff of both files computed on temp copies.
                 Writes nothing outside /tmp, uses no sudo (so the sha256
                 record, which needs root to read every file, is not computed).
  -h, --help     This text.

Paths this script can write or delete (nothing else):
  $DAEMON_JSON   overwritten by enable; restored by disable (deleted by
                 disable if it did not exist before enable)
  $NVIDIA_CONFIG   overwritten by enable; restored by disable
  $BACKUP_DIR/   created by enable (daemon.json or daemon.json.absent,
                 config.toml, default-runtime, manifest.sha256, COMPLETE);
                 deleted by disable on success
  docker.service restarted by enable and by disable
  /tmp/$PROG.XXXXXX  temp copies for dry-run planning; removed on exit

Paths read for verification (never written; every file's sha256, as root):
  /etc/docker/   /etc/nvidia-container-runtime/   /etc/cdi/
EOF
}

die() { echo "$PROG: $*" >&2; exit 1; }
bad_usage() { echo "$PROG: $*" >&2; usage >&2; exit 2; }

on_exit() {
  local rc=$?
  case "$TMP" in /tmp/"$PROG".*) rm -rf -- "$TMP" ;; esac
  if [ "$rc" -ne 0 ]; then
    if [ "$RECOVER" -eq 1 ]; then
      echo "$PROG: enable did not finish; files may have changed. Restore with:" >&2
      echo "    $SELF disable" >&2
      echo "  (works with docker stopped: it restores the files, starts docker, verifies)" >&2
    elif [ "$PARTIAL" -eq 1 ]; then
      echo "$PROG: failed while writing the backup; no host file was changed. Remove the partial backup with:" >&2
      echo "    sudo rm -rf $BACKUP_DIR" >&2
    fi
  fi
}
trap on_exit EXIT

# Print a mutating command, then run it (or only print it under --dry-run).
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] $*"
  else
    echo "+ $*"
    "$@"
  fi
}

# --- docker-dependent checks: each degrades to "unreachable"/"none", never aborts ---
docker_up() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }
default_runtime() { docker info --format '{{.DefaultRuntime}}' 2>/dev/null || echo unreachable; }
running_containers() { if docker_up; then docker ps --format '{{.Names}}' 2>/dev/null || true; fi; }
cluster_exists() {
  docker_up && command -v kind >/dev/null 2>&1 && kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"
}

key_in_config() { grep -Eq "^$KEY[[:space:]]*=[[:space:]]*true" "$NVIDIA_CONFIG" 2>/dev/null; }
cdi_in_daemon() { grep -Eq '"cdi"[[:space:]]*:[[:space:]]*true' "$DAEMON_JSON" 2>/dev/null; }

# enabled | disabled | partial
state() {
  local n=0
  if [ "$(default_runtime)" = nvidia ]; then n=$((n + 1)); fi
  if cdi_in_daemon; then n=$((n + 1)); fi
  if key_in_config; then n=$((n + 1)); fi
  case $n in 3) echo enabled ;; 0) echo disabled ;; *) echo partial ;; esac
}

show_keys() {
  echo "-- $DAEMON_JSON"
  if [ ! -e "$DAEMON_JSON" ]; then echo "   (absent)"
  elif [ ! -r "$DAEMON_JSON" ]; then echo "   (unreadable without root)"
  else grep -nE '"(default-runtime|features|cdi|nvidia)"' "$DAEMON_JSON" | sed 's/^/   /' || echo "   (no relevant keys)"; fi
  echo "-- $NVIDIA_CONFIG"
  if [ ! -r "$NVIDIA_CONFIG" ]; then echo "   (absent or unreadable)"
  else grep -nE "$KEY" "$NVIDIA_CONFIG" | sed 's/^/   /' || echo "   (key not present)"; fi
}

# --- sha256 record of the verify dirs ---
# Output: per dir "DIR <dir> present|absent", then the sorted "sha256sum" lines of
# every regular file under it. Needs root to read every file.
snapshot() {
  local d
  for d in "${VERIFY_DIRS[@]}"; do
    if [ -d "$d" ]; then   # existence is decided as you; only the read of the files uses root
      echo "DIR $d present"
      sudo find "$d" -type f -exec sha256sum {} + | LC_ALL=C sort
    else
      echo "DIR $d absent"
    fi
  done
}

# Print one line per entry in $BACKUP_DIR that this script did not write (a name
# outside BACKUP_FILES, or a known name that is not a regular file). Read-only.
backup_strays() {
  local ent t n k known
  sudo find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -printf '%y\t%f\0' |
  while IFS= read -r -d '' ent; do
    t=${ent%%$'\t'*}; n=${ent#*$'\t'}; known=0
    for k in "${BACKUP_FILES[@]}"; do
      if [ "$n" = "$k" ]; then known=1; fi
    done
    if [ "$known" -eq 0 ] || [ "$t" != f ]; then printf '  %s (type %s)\n' "$n" "$t"; fi
  done
}

# verify_record: compare the stored record with a fresh snapshot; report
# added/removed/changed entries and return 1 on any difference.
verify_record() {
  local old now
  old=$(cat "$BACKUP_DIR/manifest.sha256") || { echo "$PROG: cannot read $BACKUP_DIR/manifest.sha256" >&2; return 1; }
  now=$(snapshot) || return 1
  if [ "$old" = "$now" ]; then
    echo "verified: sha256 of every file under ${VERIFY_DIRS[*]} matches the record taken by enable"
    return 0
  fi
  echo "$PROG: files under ${VERIFY_DIRS[*]} differ from the record taken by enable:" >&2
  awk '
    function parse(line,   a) {
      if (line ~ /^DIR /) { split(line, a, " "); K = "DIR " a[2]; V = a[3] }
      else { K = substr(line, 67); V = substr(line, 1, 64) }
    }
    FNR == NR { parse($0); o[K] = V; next }
    { parse($0); n[K] = V }
    END {
      for (k in o) { if (!(k in n)) print "  removed: " k; else if (o[k] != n[k]) print "  changed: " k }
      for (k in n) if (!(k in o)) print "  added:   " k
    }' <(printf '%s\n' "$old") <(printf '%s\n' "$now") | LC_ALL=C sort >&2
  return 1
}

do_status() {
  local st running
  st=$(state)
  echo "Docker default runtime : $(default_runtime)"
  if [ -d "$BACKUP_DIR" ]; then echo "Backup                 : present ($BACKUP_DIR: $(ls "$BACKUP_DIR" 2>/dev/null | tr '\n' ' '))"
  else echo "Backup                 : none"; fi
  if [ -r "$BACKUP_DIR/manifest.sha256" ]; then
    echo "Verification record    : present ($(grep -c '^DIR ' "$BACKUP_DIR/manifest.sha256") dirs, $(grep -vc '^DIR ' "$BACKUP_DIR/manifest.sha256" || true) files)"
  elif [ -e "$BACKUP_DIR/manifest.sha256" ]; then echo "Verification record    : present (unreadable without root)"
  else echo "Verification record    : none"; fi
  if docker_up; then
    running=$(running_containers)
    echo "Running containers     : $(printf '%s' "$running" | grep -c . || true)"
    if cluster_exists; then echo "$CLUSTER_NAME cluster : exists"; else echo "$CLUSTER_NAME cluster : none"; fi
  else
    echo "Running containers     : unknown (docker unreachable)"
    echo "$CLUSTER_NAME cluster : unknown (docker unreachable)"
  fi
  show_keys
  echo "State: $st"
  [ "$st" = enabled ]
}

# Block on conditions that make a change unsafe. Under --dry-run, report them
# and carry on, then exit 1 at the end so a clean dry run really means "would work".
BLOCKED=0
block() {
  if [ "$DRY_RUN" -eq 1 ]; then echo "[dry-run] WOULD REFUSE: $*" >&2; BLOCKED=1
  else die "$*"; fi
}

wait_for_docker() {
  local i
  for i in $(seq 1 30); do
    if docker_up; then return 0; fi
    sleep 1
  done
  return 1
}

plan_diff() { # label-path current-file new-file
  echo "--- planned change to $1"
  diff -u --label "$1 (current)" --label "$1 (after)" "$2" "$3" || true
}

plan_enable() {
  TMP=$(mktemp -d "/tmp/$PROG.XXXXXX")
  local cur=/dev/null
  if [ -e "$DAEMON_JSON" ]; then cp "$DAEMON_JSON" "$TMP/daemon.json.cur"; cur=$TMP/daemon.json.cur
    cp "$DAEMON_JSON" "$TMP/daemon.json.new"; fi
  nvidia-ctk runtime configure --runtime=docker --set-as-default --cdi.enabled \
    --config "$TMP/daemon.json.new" >/dev/null 2>&1 || die "nvidia-ctk failed on the temp copy of $DAEMON_JSON"
  plan_diff "$DAEMON_JSON" "$cur" "$TMP/daemon.json.new"
  cp "$NVIDIA_CONFIG" "$TMP/config.toml.cur"; cp "$NVIDIA_CONFIG" "$TMP/config.toml.new"
  nvidia-ctk config --config-file "$TMP/config.toml.new" --set "$KEY=true" --in-place \
    >/dev/null 2>&1 || die "nvidia-ctk failed on the temp copy of $NVIDIA_CONFIG"
  plan_diff "$NVIDIA_CONFIG" "$TMP/config.toml.cur" "$TMP/config.toml.new"
}

do_enable() {
  command -v docker >/dev/null || die "docker not found"
  command -v nvidia-ctk >/dev/null || die "nvidia-ctk not found (install nvidia-container-toolkit first)"
  [ -r "$NVIDIA_CONFIG" ] || die "$NVIDIA_CONFIG not readable (is nvidia-container-toolkit installed?)"
  if [ "$(state)" = enabled ]; then echo "already enabled; nothing to do"; return 0; fi
  if [ -e "$BACKUP_DIR" ] && [ ! -e "$BACKUP_DIR/COMPLETE" ]; then
    block "$BACKUP_DIR is an incomplete backup from an enable that failed before changing any host file. Remove it with: sudo rm -rf $BACKUP_DIR"
  elif [ -e "$BACKUP_DIR" ]; then
    block "$BACKUP_DIR exists but the host is not enabled (state: $(state)). Run '$SELF disable' first; it restores from that backup and works with docker stopped."
  fi
  if ! docker_up; then
    block "docker is not reachable, so running containers cannot be checked. Start docker first; nothing was changed."
  fi
  local running; running=$(running_containers)
  if [ -n "$running" ]; then
    block "containers are running (docker restart would stop them): $(echo "$running" | tr '\n' ' ')"
  fi
  if [ "$DRY_RUN" -eq 1 ]; then plan_enable; else echo "-- sudo may prompt for a password"; run sudo -v; PARTIAL=1; fi

  run sudo mkdir -p "$BACKUP_DIR"
  if [ -e "$DAEMON_JSON" ]; then run sudo cp -a "$DAEMON_JSON" "$BACKUP_DIR/daemon.json"
  else run sudo touch "$BACKUP_DIR/daemon.json.absent"; fi
  run sudo cp -a "$NVIDIA_CONFIG" "$BACKUP_DIR/config.toml"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] record original default runtime ($(default_runtime)) in $BACKUP_DIR/default-runtime"
    echo "[dry-run] record sha256 of every file under ${VERIFY_DIRS[*]} in $BACKUP_DIR/manifest.sha256 (needs root; not computed in dry-run):"
    for d in "${VERIFY_DIRS[@]}"; do
      if [ -d "$d" ]; then echo "[dry-run]   $d: present"; else echo "[dry-run]   $d: absent (recorded as absent)"; fi
    done
  else
    echo "+ record original default runtime in $BACKUP_DIR/default-runtime"
    default_runtime | sudo tee "$BACKUP_DIR/default-runtime" >/dev/null
    echo "+ record sha256 of every file under ${VERIFY_DIRS[*]} in $BACKUP_DIR/manifest.sha256"
    snapshot | sudo tee "$BACKUP_DIR/manifest.sha256" >/dev/null
    # explicit mode, so status and disable can read both records whatever root's umask is
    run sudo chmod 0644 "$BACKUP_DIR/default-runtime" "$BACKUP_DIR/manifest.sha256"
  fi
  run sudo touch "$BACKUP_DIR/COMPLETE"
  if [ "$DRY_RUN" -eq 0 ]; then RECOVER=1; fi
  run sudo nvidia-ctk runtime configure --runtime=docker --set-as-default --cdi.enabled
  run sudo nvidia-ctk config --config-file "$NVIDIA_CONFIG" --set "$KEY=true" --in-place
  run sudo systemctl restart docker

  if [ "$DRY_RUN" -eq 1 ]; then if [ "$BLOCKED" -eq 0 ]; then return 0; else return 1; fi; fi
  wait_for_docker || die "docker did not come back after the restart"
  [ "$(default_runtime)" = nvidia ] || die "default runtime is '$(default_runtime)', expected nvidia"
  RECOVER=0
  echo "enabled: Docker default runtime is nvidia"
}

do_disable() {
  if [ ! -d "$BACKUP_DIR" ]; then
    case $(state) in
      disabled) echo "already disabled (no backup, nothing enabled); nothing to do"; return 0 ;;
      *) die "no backup at $BACKUP_DIR but state is $(state): not enabled by this script; refusing to guess a restore" ;;
    esac
  fi
  [ -e "$BACKUP_DIR/COMPLETE" ] || die "$BACKUP_DIR is incomplete: enable failed while writing it, before any host file was changed. Remove it with: sudo rm -rf $BACKUP_DIR"
  [ -e "$BACKUP_DIR/config.toml" ] || die "$BACKUP_DIR/config.toml missing; backup is incomplete, nothing changed"
  if [ ! -e "$BACKUP_DIR/daemon.json" ] && [ ! -e "$BACKUP_DIR/daemon.json.absent" ]; then
    die "$BACKUP_DIR has neither daemon.json nor daemon.json.absent; backup is incomplete, nothing changed"
  fi
  [ -e "$BACKUP_DIR/manifest.sha256" ] || die "$BACKUP_DIR/manifest.sha256 missing; cannot verify a restore, nothing changed"
  if ! docker_up; then
    echo "docker is not reachable: treating it as no running containers and no $CLUSTER_NAME cluster"
  fi
  if cluster_exists; then block "cluster $CLUSTER_NAME exists; run 'make down PROFILE=gpu-real' first"; fi
  local running; running=$(running_containers)
  if [ -n "$running" ]; then
    block "containers are running (docker restart would stop them): $(echo "$running" | tr '\n' ' ')"
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -e "$BACKUP_DIR/daemon.json" ]; then plan_diff "$DAEMON_JSON" "$DAEMON_JSON" "$BACKUP_DIR/daemon.json"
    else echo "--- $DAEMON_JSON did not exist before enable: it would be deleted"; fi
    plan_diff "$NVIDIA_CONFIG" "$NVIDIA_CONFIG" "$BACKUP_DIR/config.toml"
  else
    echo "-- sudo may prompt for a password"; run sudo -v
  fi

  if [ -e "$BACKUP_DIR/daemon.json" ]; then run sudo cp -a "$BACKUP_DIR/daemon.json" "$DAEMON_JSON"
  else run sudo rm -f "$DAEMON_JSON"; fi
  run sudo cp -a "$BACKUP_DIR/config.toml" "$NVIDIA_CONFIG"
  run sudo systemctl restart docker
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] verify: cmp backups against live files; default runtime == recorded original;"
    echo "[dry-run]   sha256 of every file under ${VERIFY_DIRS[*]} == $BACKUP_DIR/manifest.sha256 (exact match)"
    echo "[dry-run] then, only if every check passes and $BACKUP_DIR holds nothing but ${BACKUP_FILES[*]}:"
    echo "[dry-run]   sudo rm -f each of those files, then sudo rmdir $BACKUP_DIR"
    if [ "$BLOCKED" -eq 0 ]; then return 0; else return 1; fi
  fi

  local ok=1 want f
  wait_for_docker || { echo "$PROG: docker did not come back after the restart" >&2; ok=0; }
  if [ -e "$BACKUP_DIR/daemon.json" ]; then
    cmp "$BACKUP_DIR/daemon.json" "$DAEMON_JSON" || { echo "$PROG: $DAEMON_JSON differs from the backup" >&2; ok=0; }
  elif [ -e "$DAEMON_JSON" ]; then echo "$PROG: $DAEMON_JSON still exists but did not before enable" >&2; ok=0; fi
  cmp "$BACKUP_DIR/config.toml" "$NVIDIA_CONFIG" || { echo "$PROG: $NVIDIA_CONFIG differs from the backup" >&2; ok=0; }
  want=$(cat "$BACKUP_DIR/default-runtime" 2>/dev/null || echo runc)
  [ "$(default_runtime)" = "$want" ] || { echo "$PROG: default runtime is '$(default_runtime)', expected '$want'" >&2; ok=0; }
  verify_record || ok=0
  if [ "$ok" -eq 1 ]; then
    # Delete nothing unless the dir holds exactly files this script wrote. The host is
    # already restored and verified at this point; only the backup is kept.
    local strays
    strays=$(backup_strays) || die "cannot list $BACKUP_DIR; backup kept"
    if [ -n "$strays" ]; then
      echo "$PROG: unexpected entries in $BACKUP_DIR (not written by this script):" >&2
      echo "$strays" >&2
      die "files are restored and verified, but nothing was deleted; inspect and remove those entries, then run '$SELF disable' again"
    fi
    for f in "${BACKUP_FILES[@]}"; do run sudo rm -f -- "$BACKUP_DIR/$f"; done
    run sudo rmdir -- "$BACKUP_DIR"
    echo "disabled: Docker default runtime is $want; both files match the backup; verify dirs match the record"
  else
    die "verification failed; backup kept at $BACKUP_DIR"
  fi
}

main() {
  local CMD= arg
  for arg in "$@"; do
    case $arg in
      -h|--help) usage; exit 0 ;;
      -n|--dry-run) DRY_RUN=1 ;;
      status|enable|disable)
        [ -z "$CMD" ] || bad_usage "more than one subcommand: $CMD, $arg"
        CMD=$arg ;;
      *) bad_usage "unknown argument: $arg" ;;
    esac
  done
  if [ -z "$CMD" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then bad_usage "--dry-run needs enable or disable"; fi
    usage; exit 0
  fi
  if [ "$CMD" = status ] && [ "$DRY_RUN" -eq 1 ]; then bad_usage "--dry-run applies to enable and disable only"; fi
  case $CMD in
    status) do_status ;;
    enable) do_enable ;;
    disable) do_disable ;;
  esac
}

# Run only when executed, not when sourced (lets the logic be exercised in a sandbox).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
