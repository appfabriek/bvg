#!/usr/bin/env bash
# bvg uninstaller for macOS and Linux (mirror of uninstall.ps1 for Windows).
#
# Usage:
#   curl -fsSL https://github.com/appfabriek/bvg/releases/latest/download/uninstall.sh | bash
#
# Or, if bvg is already installed locally:
#   bvg-uninstall            # if a launcher was placed; otherwise run this file
#   bash uninstall.sh
#
# Options (flags or env vars):
#   --keep-files   / BVG_KEEP_FILES=1   keep config + credentials (~/.config/bvg)
#   --no-unpair    / BVG_NO_UNPAIR=1    skip server-side deregister (bvg unpair)
#
# Removes, for the current user:
#   - launchd agents (macOS) / systemd-user units (Linux): bvg + bvg-update
#   - the launcher (bvg) and lib dir (bundled Node + bvg.js)
#   - config + credentials (unless --keep-files)
# By default it first runs `bvg unpair` so the client deregisters at bvgeert
# and won't linger under /admin/clients.
set -euo pipefail

err()   { printf "\033[31m%s\033[0m\n" "$1" >&2; }
say()   { printf "\033[36m%s\033[0m\n" "$1"; }
done_() { printf "\033[32m%s\033[0m\n" "$1"; }

KEEP_FILES="${BVG_KEEP_FILES:-0}"
NO_UNPAIR="${BVG_NO_UNPAIR:-0}"
for arg in "$@"; do
  case "$arg" in
    --keep-files) KEEP_FILES=1 ;;
    --no-unpair)  NO_UNPAIR=1 ;;
    -h|--help)    grep '^#[^!]' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *) err "unknown option: $arg"; exit 1 ;;
  esac
done

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/bvg"

# --- 1. Deregister at the server (best-effort) ---------------------------
if [ "$NO_UNPAIR" != "1" ] && command -v bvg >/dev/null 2>&1; then
  say "afmelden bij de server (bvg unpair)..."
  bvg unpair 2>/dev/null || say "WARN: unpair niet gelukt — verwijder de client zo nodig in /admin/clients"
fi

# --- 2. Stop + remove the service definitions ----------------------------
case "$(uname -s)" in
  Darwin)
    for label in com.appfabriek.bvg com.appfabriek.bvg-update; do
      plist="$HOME/Library/LaunchAgents/${label}.plist"
      if [ -f "$plist" ]; then
        launchctl unload "$plist" 2>/dev/null || true
        launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
        rm -f "$plist"
        done_ "launchd-agent verwijderd: $label"
      fi
    done
    ;;
  Linux)
    UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    if command -v systemctl >/dev/null 2>&1; then
      systemctl --user disable --now bvg-update.timer 2>/dev/null || true
      systemctl --user disable --now bvg.service 2>/dev/null || true
    fi
    removed=0
    for unit in bvg.service bvg-update.service bvg-update.timer; do
      if [ -f "$UNIT_DIR/$unit" ]; then rm -f "$UNIT_DIR/$unit"; removed=1; fi
    done
    if command -v systemctl >/dev/null 2>&1; then systemctl --user daemon-reload 2>/dev/null || true; fi
    [ "$removed" = "1" ] && done_ "systemd-user units verwijderd: bvg.service + bvg-update.{service,timer}"
    ;;
  *) say "onbekend OS ($(uname -s)) — alleen bestanden worden opgeruimd" ;;
esac

# --- 3. Remove launcher + lib dir (both possible prefixes) ---------------
# /usr/local kan root vereisen; ~/.local niet. sudo alleen waar nodig en
# beschikbaar.
maybe_sudo() {
  local target="$1"
  if [ -e "$target" ] && [ ! -w "$(dirname "$target")" ] && command -v sudo >/dev/null 2>&1; then
    sudo rm -rf "$target"
  else
    rm -rf "$target"
  fi
}
for prefix in /usr/local "$HOME/.local"; do
  if [ -e "$prefix/bin/bvg" ] || [ -e "$prefix/lib/bvg" ]; then
    maybe_sudo "$prefix/bin/bvg"
    maybe_sudo "$prefix/lib/bvg"
    done_ "verwijderd: $prefix/bin/bvg + $prefix/lib/bvg"
  fi
done

# --- 4. Config + credentials ---------------------------------------------
if [ "$KEEP_FILES" = "1" ]; then
  say "config + credentials behouden: $CONFIG_DIR"
elif [ -d "$CONFIG_DIR" ]; then
  rm -rf "$CONFIG_DIR"
  done_ "config + credentials verwijderd: $CONFIG_DIR"
fi

done_ "bvg uninstall voltooid"
