#!/bin/bash
# Init container: prepares the ZeroClaw state and workspace volumes.
#
# config.toml
#   ZEROCLAW_CONFIG_SEED=always (default): $HOME/.zeroclaw/config.toml is
#     rewritten from the zeroclaw-config ConfigMap on every pod start, so the
#     ConfigMap stays the source of truth. The one runtime-written key carried
#     over is `gateway.paired_tokens` (dashboard/API pairings, stored
#     encrypted), so a restart does not unpair clients. Other runtime edits
#     (`zeroclaw config set`, dashboard settings) are discarded on restart.
#   ZEROCLAW_CONFIG_SEED=once: copy only when no config.toml exists yet; from
#     then on the file on the volume belongs to the daemon.
#
# Workspace files
#   Each key `<dir>__<file>` of the zeroclaw-workspace-files ConfigMap is
#   copied to $WORKSPACES_ROOT/<dir>/<file> (general__SOUL.md ->
#   /workspaces/general/SOUL.md), overwriting the previous copy.
#   WORKSPACE_DIRS lists directories to create even without files.
set -euo pipefail

src_config=/etc/zeroclaw/config/config.toml
files_dir=/etc/zeroclaw/workspace-files
state_dir="${HOME:?HOME must be set}/.zeroclaw"
workspaces="${WORKSPACES_ROOT:-/workspaces}"
mode="${ZEROCLAW_CONFIG_SEED:-always}"
dst="$state_dir/config.toml"

log() { printf 'seed: %s\n' "$*"; }
die() { printf 'seed: %s\n' "$*" >&2; exit 1; }

case "$mode" in
  always | once) ;;
  *) die "ZEROCLAW_CONFIG_SEED must be 'always' or 'once', got '$mode'" ;;
esac
[ -f "$src_config" ] || die "missing $src_config (zeroclaw-config ConfigMap)"

install -d -m 0700 "$state_dir"

if [ "$mode" = once ] && [ -f "$dst" ]; then
  log "$dst exists and ZEROCLAW_CONFIG_SEED=once: left untouched"
else
  if grep -Eq '^[[:space:]]*paired_tokens[[:space:]]*=' "$src_config"; then
    die "the ConfigMap config.toml must not set gateway.paired_tokens (runtime state)"
  fi
  tokens=""
  if [ -f "$dst" ]; then
    # `paired_tokens = [ ... ]`, on one line or spread over several.
    tokens="$(awk '/^[[:space:]]*paired_tokens[[:space:]]*=/ { p = 1 } p { print } p && /\]/ { exit }' "$dst")"
  fi
  tmp="$(mktemp "$state_dir/.config.toml.XXXXXX")"
  if [ -n "$tokens" ]; then
    # Re-insert right below the [gateway] header (or append the table).
    TOKENS="$tokens" awk '
      { print }
      !done && /^[[:space:]]*\[gateway\][[:space:]]*(#.*)?$/ { print ENVIRON["TOKENS"]; done = 1 }
      END { if (!done) { print ""; print "[gateway]"; print ENVIRON["TOKENS"] } }
    ' "$src_config" >"$tmp"
    log "carried over gateway.paired_tokens"
  else
    cat "$src_config" >"$tmp"
  fi
  chmod 0600 "$tmp"
  mv -f "$tmp" "$dst"
  log "wrote $dst from the ConfigMap (mode=$mode)"
fi

# The volume root belongs to the storage provisioner; only check it.
[ -w "$workspaces" ] || die "$workspaces is not writable (fsGroup / volume permissions)"
for dir in ${WORKSPACE_DIRS:-}; do
  case "$dir" in */* | .* | '') die "invalid WORKSPACE_DIRS entry '$dir'" ;; esac
  install -d -m 0700 "$workspaces/$dir"
done

shopt -s nullglob
for f in "$files_dir"/*__*; do
  key="${f##*/}"
  dir="${key%%__*}"
  name="${key#*__}"
  case "$dir" in */* | .* | '') die "invalid workspace-files key '$key'" ;; esac
  case "$name" in */* | .* | '') die "invalid workspace-files key '$key'" ;; esac
  install -d -m 0700 "$workspaces/$dir"
  install -m 0600 "$f" "$workspaces/$dir/$name"
  log "$key -> $workspaces/$dir/$name"
done
