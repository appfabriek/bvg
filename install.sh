#!/usr/bin/env bash
# bvg installer for macOS and Linux (Dart wire-client).
#
# Downloads the self-contained `bvg` Dart binary from the latest release,
# optionally enrolls it against the bvgeert transport over Azure using a
# one-time join-token, and installs a user-level service that runs `bvg launch`
# (which applies any pending self-update then runs the daemon). Without a join
# token the client installs in anonymous (pre-enroll) mode and can be enrolled
# later.
#
# Usage (the bvg1 proxy snippet / bvgeert admin UI generates this line):
#   curl -fsSL https://github.com/appfabriek/bvg/releases/latest/download/install.sh \
#     | BVG_JOIN_TOKEN=jt_xxx \
#       BVG_ANON_BOOTSTRAP_URL=https://bvg1.example/anon \
#       BVG_TRANSPORT=my-connection bash
#
# Required env vars:
#   BVG_ANON_BOOTSTRAP_URL  bvg1 anon-access endpoint; the client uses it to
#                           obtain anonymous Azure access URLs
#   BVG_TRANSPORT           transport / connection identifier
#
# Optional env vars:
#   BVG_JOIN_TOKEN          one-time join token (jt_...); if set, enroll now,
#                           otherwise install in anonymous (pre-enroll) mode
#   BVG_NO_SERVICE          1/true => download (+ enroll if token) but do not
#                           install or start the service; print the manual
#                           run-command instead (also via --no-service arg)
#   BVG_INSTALL_DIR         install dir (default: $HOME/.bvg)
#   BVG_INSTALL_BASE_URL    release asset base URL
#                           (default: github.com/appfabriek/bvg latest)
#   BVG_CREDENTIALS         credentials path (default: <install-dir>/credentials.json)
set -euo pipefail

BASE_URL="${BVG_INSTALL_BASE_URL:-https://github.com/appfabriek/bvg/releases/latest/download}"

err()   { printf "\033[31m%s\033[0m\n" "$1" >&2; }
say()   { printf "\033[36m%s\033[0m\n" "$1"; }
done_() { printf "\033[32m%s\033[0m\n" "$1"; }

command -v curl >/dev/null 2>&1 || { err "curl not found"; exit 1; }

# --- 0. Parse args / resolve no-service flag -----------------------------
NO_SERVICE=0
case "${BVG_NO_SERVICE:-}" in 1|true|TRUE|True|yes|YES) NO_SERVICE=1;; esac
for arg in "$@"; do
  case "$arg" in
    --no-service) NO_SERVICE=1;;
  esac
done

# --- 1. Require config env-vars ------------------------------------------
# BVG_JOIN_TOKEN is OPTIONAL (tokenless = anonymous pre-enroll mode).
# The anonymous daemon still needs the bootstrap url + transport, so those
# stay required.
missing=0
[ -n "${BVG_ANON_BOOTSTRAP_URL:-}" ] || { err "BVG_ANON_BOOTSTRAP_URL is required"; missing=1; }
[ -n "${BVG_TRANSPORT:-}" ]          || { err "BVG_TRANSPORT is required";          missing=1; }
if [ "$missing" = "1" ]; then
  err "set BVG_ANON_BOOTSTRAP_URL and BVG_TRANSPORT and re-run."
  exit 1
fi

# --- 2. Detect platform and map to a release asset -----------------------
OS="$(uname -s)"
MACHINE="$(uname -m)"
case "$MACHINE" in
  x86_64|amd64)        ARCH="x64";;
  arm64|aarch64)       ARCH="arm64";;
  *) err "unsupported architecture: $MACHINE"; exit 1;;
esac

case "$OS" in
  Linux)
    ASSET="bvg-linux-x64"
    ;;
  Darwin)
    case "$ARCH" in
      arm64) ASSET="bvg-macos-arm64";;
      x64)   ASSET="bvg-macos-x64";;
      *)     err "unsupported macOS architecture: $MACHINE"; exit 1;;
    esac
    ;;
  *)
    err "unsupported OS: $OS"; exit 1
    ;;
esac
say "platform: $OS/$MACHINE -> asset $ASSET"

# --- 3. Download the binary ----------------------------------------------
DIR="${BVG_INSTALL_DIR:-$HOME/.bvg}"
BIN="$DIR/bvg"
mkdir -p "$DIR"

say "downloading $ASSET to $BIN..."
# curl-downloaded binaries do NOT get the macOS Gatekeeper quarantine xattr,
# so no codesign/notarization dance is needed for this CLI path.
curl -fsSL -o "$BIN" "$BASE_URL/$ASSET"
chmod +x "$BIN"
done_ "bvg installed to $BIN"

# --- 3b. Put `bvg` on PATH -----------------------------------------------
# Symlink the binary into a PATH dir so `bvg ...` works from any shell. Prefer
# /usr/local/bin when writable (already on PATH everywhere); otherwise
# ~/.local/bin, adding it to the shell rc files if it isn't on PATH yet.
if [ -w /usr/local/bin ] 2>/dev/null; then
  LINK_DIR="/usr/local/bin"
else
  LINK_DIR="$HOME/.local/bin"
  mkdir -p "$LINK_DIR"
fi
if ln -sf "$BIN" "$LINK_DIR/bvg" 2>/dev/null; then
  done_ "linked $LINK_DIR/bvg -> $BIN"
  case ":$PATH:" in
    *":$LINK_DIR:"*) ;;
    *)
      for rc in "$HOME/.profile" "$HOME/.zshrc" "$HOME/.bashrc"; do
        { [ "$rc" = "$HOME/.profile" ] || [ -e "$rc" ]; } || continue
        grep -qs "added by bvg installer" "$rc" 2>/dev/null && continue
        printf '\n# added by bvg installer\nexport PATH="%s:$PATH"\n' "$LINK_DIR" >> "$rc" 2>/dev/null || true
      done
      say "added $LINK_DIR to PATH (open a new shell, or: export PATH=\"$LINK_DIR:\$PATH\")"
      ;;
  esac
else
  say "note: could not put bvg on PATH; invoke it as $BIN"
fi

# --- 4. Enroll (one-time, redeem the join token) -- or skip (anonymous) --
CREDENTIALS="${BVG_CREDENTIALS:-$DIR/credentials.json}"
export BVG_CREDENTIALS="$CREDENTIALS"
export BVG_ANON_BOOTSTRAP_URL
export BVG_TRANSPORT

if [ -n "${BVG_JOIN_TOKEN:-}" ]; then
  if [ -f "$CREDENTIALS" ] && grep -q '"client_id"' "$CREDENTIALS" 2>/dev/null; then
    # Idempotent re-install: existing credentials carry an Ed25519 keypair that
    # is already registered server-side. Re-enrolling would mint a NEW client
    # but re-send the SAME public key, which the server rejects (duplicate key)
    # -> auth fails. So reuse the existing identity instead.
    say "existing credentials found at $CREDENTIALS -> reusing (skip enroll)"
    say "to force a fresh enroll, remove $CREDENTIALS first"
  else
    say "enrolling with bvgeert (transport=$BVG_TRANSPORT)..."
    "$BIN" enroll \
      --token "$BVG_JOIN_TOKEN" \
      --bootstrap "$BVG_ANON_BOOTSTRAP_URL" \
      --transport "$BVG_TRANSPORT" \
      --hostname "$(hostname)"
    done_ "enrolled; credentials at $CREDENTIALS"
  fi
else
  say "no token -> installing in anonymous (pre-enroll) mode; enroll later with: bvg enroll --token <jt> --bootstrap $BVG_ANON_BOOTSTRAP_URL --transport $BVG_TRANSPORT --hostname $(hostname)"
fi

# --- 4a. Remove any legacy (pre-Dart) bvg install -------------------------
# Older clients ran a Node bvg under ~/.local/lib/bvg (Linux, via a systemd
# user unit) or a launchd agent com.appfabriek.bvg (macOS). Left in place the
# legacy systemd unit crash-loops and fights the Dart service for the same
# name; remove it. The NEW mac agent is nl.bvgeert.bvg, so wiping the old
# com.appfabriek.* namespace is safe.
case "$OS" in
  Linux)
    if [ -d "$HOME/.local/lib/bvg" ] || [ -x "$HOME/.local/bin/bvg" ]; then
      say "removing legacy Node bvg install..."
      if command -v systemctl >/dev/null 2>&1; then
        systemctl --user stop bvg.service 2>/dev/null || true
        systemctl --user disable bvg.service 2>/dev/null || true
      fi
      rm -rf "$HOME/.local/lib/bvg" "$HOME/.local/bin/bvg"
    fi
    ;;
  Darwin)
    for legacy in "$HOME"/Library/LaunchAgents/com.appfabriek.bvg*.plist; do
      [ -f "$legacy" ] || continue
      say "removing legacy launchd agent $(basename "$legacy")..."
      launchctl unload "$legacy" 2>/dev/null || true
      rm -f "$legacy"
    done
    ;;
esac

# --- 4b. No-service mode: stop before touching any service ---------------
# The daemon auto-selects: enrolled creds -> full agent; not enrolled ->
# anonymous pre-enroll daemon. Run it manually with the env vars below.
if [ "$NO_SERVICE" = "1" ]; then
  done_ "download complete; service NOT installed (BVG_NO_SERVICE)"
  echo ""
  echo "run the daemon manually with:"
  echo "  BVG_CREDENTIALS=\"$CREDENTIALS\" BVG_ANON_BOOTSTRAP_URL=\"$BVG_ANON_BOOTSTRAP_URL\" BVG_TRANSPORT=\"$BVG_TRANSPORT\" \"$BIN\" daemon"
  echo ""
  echo "binary:       $BIN"
  echo "credentials:  $CREDENTIALS"
  echo "transport:    $BVG_TRANSPORT"
  exit 0
fi

# --- 5. Install a user-level service running `bvg launch` -----------------
SERVICE_DESC=""
case "$OS" in
  Darwin)
    PLIST="$HOME/Library/LaunchAgents/nl.bvgeert.bvg.plist"
    mkdir -p "$(dirname "$PLIST")"
    cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>nl.bvgeert.bvg</string>
  <key>ProgramArguments</key><array>
    <string>$BIN</string>
    <string>launch</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>BVG_CREDENTIALS</key><string>$CREDENTIALS</string>
    <key>BVG_ANON_BOOTSTRAP_URL</key><string>$BVG_ANON_BOOTSTRAP_URL</string>
    <key>BVG_TRANSPORT</key><string>$BVG_TRANSPORT</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/bvg.log</string>
  <key>StandardErrorPath</key><string>/tmp/bvg.err</string>
</dict>
</plist>
EOF
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    SERVICE_DESC="launchd agent nl.bvgeert.bvg (load: launchctl load $PLIST)"
    done_ "launchd agent loaded: nl.bvgeert.bvg"
    ;;
  Linux)
    UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    UNIT="$UNIT_DIR/bvg.service"
    mkdir -p "$UNIT_DIR"
    cat >"$UNIT" <<EOF
[Unit]
Description=BvGeert transport daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN launch
Restart=always
RestartSec=5
Environment=BVG_CREDENTIALS=$CREDENTIALS
Environment=BVG_ANON_BOOTSTRAP_URL=$BVG_ANON_BOOTSTRAP_URL
Environment=BVG_TRANSPORT=$BVG_TRANSPORT

[Install]
WantedBy=default.target
EOF
    # systemctl --user needs a user bus. A headless server reached over SSH has
    # no graphical session, hence no bus -> the service would never start or
    # survive logout. Enable lingering (systemd spawns a persistent user
    # manager at boot) and point at its runtime dir, then wait for the bus.
    # Falls back to a manual run-command only if there's no systemd at all.
    : "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
    export XDG_RUNTIME_DIR
    if command -v loginctl >/dev/null 2>&1; then
      loginctl enable-linger "$(id -un)" 2>/dev/null || true
    fi
    bus_ok=0
    for _ in 1 2 3 4 5; do
      if systemctl --user show-environment >/dev/null 2>&1; then bus_ok=1; break; fi
      sleep 1
    done
    if [ "$bus_ok" = "1" ]; then
      systemctl --user daemon-reload
      systemctl --user enable --now bvg.service
      SERVICE_DESC="systemd user unit bvg.service (status: systemctl --user status bvg)"
      done_ "systemd user service running: bvg.service"
    else
      say "systemctl --user is unavailable (no user bus) - unit written to $UNIT"
      say "start the daemon manually with:"
      say "  BVG_CREDENTIALS=\"$CREDENTIALS\" BVG_ANON_BOOTSTRAP_URL=\"$BVG_ANON_BOOTSTRAP_URL\" BVG_TRANSPORT=\"$BVG_TRANSPORT\" \"$BIN\" daemon"
      say "or, once a user bus exists:"
      say "  loginctl enable-linger \"\$USER\" && systemctl --user enable --now bvg.service"
      SERVICE_DESC="manual: BVG_CREDENTIALS=\"$CREDENTIALS\" BVG_ANON_BOOTSTRAP_URL=\"$BVG_ANON_BOOTSTRAP_URL\" BVG_TRANSPORT=\"$BVG_TRANSPORT\" \"$BIN\" daemon"
    fi
    ;;
esac

# --- 6. Success summary ---------------------------------------------------
done_ "installation complete"
echo ""
echo "binary:       $BIN"
echo "credentials:  $CREDENTIALS"
echo "transport:    $BVG_TRANSPORT"
echo "service:      $SERVICE_DESC"
echo ""
echo "status:       BVG_CREDENTIALS=\"$CREDENTIALS\" \"$BIN\" status"
