#!/usr/bin/env bash
# bvg installer for macOS and Linux (Dart wire-client).
#
# Downloads the self-contained `bvg` Dart binary from the latest release,
# enrolls it against the bvgeert transport over Azure using a one-time
# join-token, and installs a user-level service that runs `bvg daemon`.
#
# Usage (the bvg1 proxy snippet / bvgeert admin UI generates this line):
#   curl -fsSL https://github.com/appfabriek/bvg/releases/latest/download/install.sh \
#     | BVG_JOIN_TOKEN=jt_xxx \
#       BVG_ANON_BOOTSTRAP_URL=https://bvg1.example/anon \
#       BVG_TRANSPORT=my-connection bash
#
# Required env vars:
#   BVG_JOIN_TOKEN          one-time join token (jt_...)
#   BVG_ANON_BOOTSTRAP_URL  bvg1 anon-access endpoint; the client uses it to
#                           obtain anonymous Azure access URLs
#   BVG_TRANSPORT           transport / connection identifier
#
# Optional env vars:
#   BVG_BVGEERT_HOST        bvgeert hostname (informational, may be present)
#   BVG_AZURE_HUB           Azure Web PubSub hub (informational, may be present)
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

# --- 1. Require config env-vars ------------------------------------------
missing=0
[ -n "${BVG_JOIN_TOKEN:-}" ]         || { err "BVG_JOIN_TOKEN is required";         missing=1; }
[ -n "${BVG_ANON_BOOTSTRAP_URL:-}" ] || { err "BVG_ANON_BOOTSTRAP_URL is required"; missing=1; }
[ -n "${BVG_TRANSPORT:-}" ]          || { err "BVG_TRANSPORT is required";          missing=1; }
if [ "$missing" = "1" ]; then
  err "set BVG_JOIN_TOKEN, BVG_ANON_BOOTSTRAP_URL and BVG_TRANSPORT and re-run."
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

# --- 4. Enroll (one-time, redeem the join token) -------------------------
CREDENTIALS="${BVG_CREDENTIALS:-$DIR/credentials.json}"
export BVG_CREDENTIALS="$CREDENTIALS"

say "enrolling with bvgeert (transport=$BVG_TRANSPORT)..."
"$BIN" enroll \
  --token "$BVG_JOIN_TOKEN" \
  --bootstrap "$BVG_ANON_BOOTSTRAP_URL" \
  --transport "$BVG_TRANSPORT" \
  --hostname "$(hostname)"
done_ "enrolled; credentials at $CREDENTIALS"

# --- 5. Install a user-level service running `bvg daemon` -----------------
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
    <string>daemon</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>BVG_CREDENTIALS</key><string>$CREDENTIALS</string>
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
ExecStart=$BIN daemon
Restart=always
RestartSec=5
Environment=BVG_CREDENTIALS=$CREDENTIALS

[Install]
WantedBy=default.target
EOF
    # systemctl --user needs a session/user bus. On headless boxes without one
    # it fails; don't break the install, just tell the operator how to run it.
    if systemctl --user show-environment >/dev/null 2>&1; then
      systemctl --user daemon-reload
      systemctl --user enable --now bvg.service
      SERVICE_DESC="systemd user unit bvg.service (status: systemctl --user status bvg)"
      done_ "systemd user service running: bvg.service"
    else
      say "systemctl --user is unavailable (no session bus) - unit written to $UNIT"
      say "start the daemon manually with:"
      say "  BVG_CREDENTIALS=\"$CREDENTIALS\" \"$BIN\" daemon"
      say "or enable lingering + the unit once a user bus exists:"
      say "  loginctl enable-linger \"\$USER\" && systemctl --user enable --now bvg.service"
      SERVICE_DESC="manual: BVG_CREDENTIALS=\"$CREDENTIALS\" \"$BIN\" daemon"
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
