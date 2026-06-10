#!/usr/bin/env bash
# bvg uninstaller for macOS and Linux (Dart wire-client).
#
# Usage:
#   curl -fsSL https://github.com/appfabriek/bvg/releases/latest/download/uninstall.sh | bash
#
# If `bvg` is on PATH you can equivalently run: `bvg uninstall`.
#
# Options (flags or env vars):
#   --keep-files / BVG_KEEP_FILES=1   keep ~/.bvg (binary + credentials)
#
# Removes, for the current user:
#   - the service: launchd agent nl.bvgeert.bvg (macOS) / systemd-user
#     bvg.service (Linux), plus any legacy com.appfabriek.bvg* agents
#   - the PATH symlink (/usr/local/bin/bvg or ~/.local/bin/bvg)
#   - the install dir ~/.bvg (binary + credentials), unless --keep-files
set -euo pipefail

say()   { printf "\033[36m%s\033[0m\n" "$1"; }
done_() { printf "\033[32m%s\033[0m\n" "$1"; }

KEEP_FILES="${BVG_KEEP_FILES:-0}"
for arg in "$@"; do
  case "$arg" in
    --keep-files) KEEP_FILES=1 ;;
    -h|--help)    grep '^#[^!]' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *) printf "unknown option: %s\n" "$arg" >&2; exit 1 ;;
  esac
done

INSTALL_DIR="${BVG_INSTALL_DIR:-$HOME/.bvg}"

# --- 1. Stop + remove the service ----------------------------------------
case "$(uname -s)" in
  Darwin)
    for label in nl.bvgeert.bvg com.appfabriek.bvg com.appfabriek.bvg-update; do
      plist="$HOME/Library/LaunchAgents/${label}.plist"
      if [ -f "$plist" ]; then
        launchctl unload "$plist" 2>/dev/null || true
        launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
        rm -f "$plist"
        done_ "removed launchd agent: $label"
      fi
    done
    ;;
  Linux)
    : "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
    export XDG_RUNTIME_DIR
    UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    if command -v systemctl >/dev/null 2>&1; then
      systemctl --user disable --now bvg.service 2>/dev/null || true
    fi
    removed=0
    for unit in bvg.service bvg-update.service bvg-update.timer; do
      if [ -f "$UNIT_DIR/$unit" ]; then rm -f "$UNIT_DIR/$unit"; removed=1; fi
    done
    if command -v systemctl >/dev/null 2>&1; then systemctl --user daemon-reload 2>/dev/null || true; fi
    [ "$removed" = "1" ] && done_ "removed systemd-user unit: bvg.service"
    ;;
  *) say "unknown OS ($(uname -s)) - only files will be cleaned up" ;;
esac

# --- 2. Remove the PATH symlink ------------------------------------------
maybe_sudo_rm() {
  local target="$1"
  [ -e "$target" ] || [ -L "$target" ] || return 0
  if [ -w "$(dirname "$target")" ]; then
    rm -f "$target"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo rm -f "$target"
  else
    say "note: could not remove $target (needs root); remove it manually"
    return 0
  fi
  done_ "removed PATH symlink: $target"
}
maybe_sudo_rm /usr/local/bin/bvg
maybe_sudo_rm "$HOME/.local/bin/bvg"

# --- 3. Remove the install dir (binary + credentials) --------------------
if [ "$KEEP_FILES" = "1" ]; then
  say "keeping files: $INSTALL_DIR"
elif [ -d "$INSTALL_DIR" ]; then
  rm -rf "$INSTALL_DIR"
  done_ "removed: $INSTALL_DIR"
fi

done_ "bvg uninstall complete"
say "note: this client may still show (offline) under /admin/clients - remove it there to fully deregister."
