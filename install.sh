#!/usr/bin/env bash
# bvg installer for macOS and Linux.
#
# Usage:
#   curl -fsSL https://github.com/appfabriek/bvg/releases/latest/download/install.sh | bash
#
# One-shot install + pair (recommended — the bvgeert admin UI generates
# this line for you):
#   curl -fsSL https://github.com/appfabriek/bvg/releases/latest/download/install.sh \
#     | BVG_JOIN_TOKEN=jt_xxx BVG_BVGEERT_HOST=bvgeert.example bash
#
# Env vars (auto-pair triggers when JOIN_TOKEN + a route are both present):
#   BVG_JOIN_TOKEN     one-time pre-approved join token (jt_…)
#   BVG_BVGEERT_HOST   bvgeert hostname for direct HTTPS+WSS route (preferred)
#   BVG_AZURE_HUB      Azure Web PubSub WSS URL (fallback for restricted networks)
#   BVG_TRANSPORT      transport / connection identifier (optional, server
#                      derives from the join-token)
#   BVG_DOMAIN         optional metadata, stored in install.env for reference
#   BVG_PORTABLE       1/true → service-loze install (geen launchd/systemd-user
#                      agent, geen self-update-timer); start zelf met `bvg daemon`.
#                      Gelijk aan de --portable vlag.
#
# Installs Node.js (if missing), downloads the bvg bundle, places a
# launcher script in /usr/local/bin/bvg (or ~/.local/bin), and
# attempts to install a system service (launchd on macOS, systemd-user on
# Linux). Auto-pair runs in the foreground so you see the result.
set -euo pipefail

REPO="appfabriek/bvg"
INSTALL_PREFIX="${BVG_PREFIX:-/usr/local}"
NODE_VERSION="${BVG_NODE_VERSION:-22.11.0}"

# Portable (service-loze) install: installeer + pair, maar GEEN launchd-agent /
# systemd-user-unit en geen self-update-timer. Starten doe je zelf met
# `bvg daemon`. Opt-in via BVG_PORTABLE=1 of de --portable vlag; de mac/linux-
# install is sowieso al user-level (geen sudo).
PORTABLE=0
case "${BVG_PORTABLE:-}" in 1|true|yes) PORTABLE=1 ;; esac
for _a in "$@"; do [ "$_a" = "--portable" ] && PORTABLE=1; done

err()  { printf "\033[31m%s\033[0m\n" "$1" >&2; }
say()  { printf "\033[36m%s\033[0m\n" "$1"; }
done_() { printf "\033[32m%s\033[0m\n" "$1"; }

require_curl() { command -v curl >/dev/null 2>&1 || { err "curl not found"; exit 1; }; }
require_curl

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print tolower($1)}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print tolower($1)}'
  else
    err "no sha256sum or shasum found - cannot verify downloads"
    exit 1
  fi
}

verify_sha256() {
  local file="$1"
  local sha_url="$2"
  local expected actual

  expected="$(curl -fsSL --max-time 30 "$sha_url" | awk '{print tolower($1)}')"
  if [ -z "$expected" ]; then
    err "empty checksum from $sha_url"
    exit 1
  fi

  actual="$(sha256_file "$file")"
  if [ "$actual" != "$expected" ]; then
    err "sha256 mismatch for $(basename "$file")"
    err "downloaded=$actual expected=$expected"
    exit 1
  fi
}

# --- Pre-flight checks ---------------------------------------------------
# Disk space (need ~250MB for Node bundle + Node-runtime download fallback)
case "$(uname -s)" in
  Linux|Darwin)
    free_mb="$(df -m "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [ -n "${free_mb:-}" ] && [ "$free_mb" -lt 250 ]; then
      err "less than 250 MB free in $HOME — install needs ~200 MB"; exit 1
    fi
    ;;
esac
# GitHub reachability — warn (don't fail) so corp proxies don't break things
if ! curl -fsS --max-time 5 -o /dev/null https://github.com/ 2>/dev/null; then
  say "WARN: github.com not reachable in 5s — download likely to fail"
fi

# Pick install prefix that's writable (drop to ~/.local if needed).
if [ ! -w "$INSTALL_PREFIX/bin" ] && [ "$INSTALL_PREFIX" = "/usr/local" ]; then
  INSTALL_PREFIX="$HOME/.local"
  mkdir -p "$INSTALL_PREFIX/bin"
fi
BIN_DIR="$INSTALL_PREFIX/bin"
LIB_DIR="$INSTALL_PREFIX/lib/bvg"
mkdir -p "$BIN_DIR" "$LIB_DIR"

# Detect platform.
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$OS-$ARCH" in
  linux-x86_64)  NODE_TARBALL="node-v${NODE_VERSION}-linux-x64";;
  linux-aarch64) NODE_TARBALL="node-v${NODE_VERSION}-linux-arm64";;
  darwin-arm64)  NODE_TARBALL="node-v${NODE_VERSION}-darwin-arm64";;
  darwin-x86_64) NODE_TARBALL="node-v${NODE_VERSION}-darwin-x64";;
  *) err "unsupported platform $OS-$ARCH"; exit 1;;
esac

# Install Node locally if not already on PATH.
NODE_BIN=""
if command -v node >/dev/null 2>&1; then
  NODE_BIN="$(command -v node)"
  say "using existing node: $NODE_BIN ($(node --version))"
else
  NODE_DIR="$LIB_DIR/node-v${NODE_VERSION}"
  if [ ! -x "$NODE_DIR/bin/node" ]; then
    say "downloading Node.js ${NODE_VERSION} for $OS-$ARCH..."
    NODE_ARCHIVE="$LIB_DIR/${NODE_TARBALL}.tar.xz"
    NODE_SHASUMS_URL="https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"
    curl -fsSL -o "$NODE_ARCHIVE" "https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TARBALL}.tar.xz"
    NODE_EXPECTED_HASH="$(curl -fsSL "$NODE_SHASUMS_URL" | awk -v file="${NODE_TARBALL}.tar.xz" '$2 == file {print tolower($1)}')"
    NODE_ACTUAL_HASH="$(sha256_file "$NODE_ARCHIVE")"
    if [ -z "$NODE_EXPECTED_HASH" ] || [ "$NODE_ACTUAL_HASH" != "$NODE_EXPECTED_HASH" ]; then
      err "sha256 mismatch for ${NODE_TARBALL}.tar.xz"
      err "downloaded=$NODE_ACTUAL_HASH expected=$NODE_EXPECTED_HASH"
      exit 1
    fi
    tar -xJ -C "$LIB_DIR" -f "$NODE_ARCHIVE"
    rm -f "$NODE_ARCHIVE"
    mv "$LIB_DIR/${NODE_TARBALL}" "$NODE_DIR"
  fi
  NODE_BIN="$NODE_DIR/bin/node"
fi

# Download the bundled CLI from the latest release and require checksum match.
say "downloading bvg bundle..."
BUNDLE_URL="https://github.com/${REPO}/releases/latest/download/bvg.js"
BUNDLE_SHA_URL="https://github.com/${REPO}/releases/latest/download/bvg.js.sha256"
BUNDLE_TMP="$(mktemp -t bvg.XXXXXXXX.js)"
curl -fsSL -o "$BUNDLE_TMP" "$BUNDLE_URL"
verify_sha256 "$BUNDLE_TMP" "$BUNDLE_SHA_URL"
mv "$BUNDLE_TMP" "$LIB_DIR/bvg.js"

# Wrapper script.
cat >"$BIN_DIR/bvg" <<EOF
#!/usr/bin/env bash
exec "$NODE_BIN" "$LIB_DIR/bvg.js" "\$@"
EOF
chmod +x "$BIN_DIR/bvg"

done_ "bvg installed to $BIN_DIR/bvg"

# --- Self-update bookkeeping --------------------------------------------
# Pull the updater script + a version.txt sibling for later semver-compare.
UPDATER_URL="https://github.com/${REPO}/releases/latest/download/bvg-update.sh"
UPDATER_SHA_URL="https://github.com/${REPO}/releases/latest/download/bvg-update.sh.sha256"
VERSION_URL="https://github.com/${REPO}/releases/latest/download/version.txt"
UPDATER_TMP="$(mktemp -t bvg-update.XXXXXXXX.sh)"
curl -fsSL -o "$UPDATER_TMP" --max-time 30 "$UPDATER_URL"
verify_sha256 "$UPDATER_TMP" "$UPDATER_SHA_URL"
mv "$UPDATER_TMP" "$LIB_DIR/bvg-update.sh"
chmod +x "$LIB_DIR/bvg-update.sh"
curl -fsSL -o "$LIB_DIR/version.txt" --max-time 30 "$VERSION_URL" 2>/dev/null || \
  printf '0.0.0' > "$LIB_DIR/version.txt"

# Decide pairing route from env-vars.
HAS_TOKEN="${BVG_JOIN_TOKEN:-}"
PAIRED=0
if [ -n "$HAS_TOKEN" ]; then
  CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/bvg"
  mkdir -p "$CONFIG_DIR"
  CONFIG_ENV="$CONFIG_DIR/install.env"
  {
    [ -n "${BVG_DOMAIN:-}" ]       && echo "BVG_DOMAIN=$BVG_DOMAIN"
    [ -n "${BVG_BVGEERT_HOST:-}" ] && echo "BVG_BVGEERT_HOST=$BVG_BVGEERT_HOST"
    [ -n "${BVG_AZURE_HUB:-}" ]    && echo "BVG_AZURE_HUB=$BVG_AZURE_HUB"
    [ -n "${BVG_TRANSPORT:-}" ]    && echo "BVG_TRANSPORT=$BVG_TRANSPORT"
  } > "$CONFIG_ENV"
  chmod 600 "$CONFIG_ENV"

  if [ -n "${BVG_BVGEERT_HOST:-}" ]; then
    say "pairing with bvgeert directly at $BVG_BVGEERT_HOST..."
    "$BIN_DIR/bvg" join --host "$BVG_BVGEERT_HOST" --token "$HAS_TOKEN" \
      ${BVG_TRANSPORT:+--transport "$BVG_TRANSPORT"} && PAIRED=1 || PAIRED=0
  elif [ -n "${BVG_AZURE_HUB:-}" ]; then
    TRANSPORT="${BVG_TRANSPORT:-default}"
    say "pairing with bvgeert via Azure (transport=$TRANSPORT)..."
    "$BIN_DIR/bvg" join --hub "$BVG_AZURE_HUB" --transport "$TRANSPORT" --token "$HAS_TOKEN" \
      && PAIRED=1 || PAIRED=0
  fi
fi

# Install system service when paired (tenzij portable).
if [ "$PAIRED" = "1" ] && [ "$PORTABLE" = "1" ]; then
  done_ "portable (service-loze) install — geen launchd/systemd-user agent, geen self-update-timer"
  say "starten:  bvg daemon       (of: $BIN_DIR/bvg daemon)"
  say "config:   $CONFIG_DIR"
  say "geen auto-start: draai 'bvg daemon' zelf wanneer je wilt"
  exit 0
fi
if [ "$PAIRED" = "1" ]; then
  case "$OS" in
    linux)
      UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
      mkdir -p "$UNIT_DIR"
      cat >"$UNIT_DIR/bvg.service" <<EOF
[Unit]
Description=BvGeert transport daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_DIR/bvg daemon
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
      # --- Daily self-update timer (Linux systemd-user) ---
      if [ -x "$LIB_DIR/bvg-update.sh" ]; then
        cat >"$UNIT_DIR/bvg-update.service" <<EOF
[Unit]
Description=BvGeert transport daemon — self-update check

[Service]
Type=oneshot
ExecStart=$LIB_DIR/bvg-update.sh
EOF
        cat >"$UNIT_DIR/bvg-update.timer" <<EOF
[Unit]
Description=Run bvg self-update daily

[Timer]
OnBootSec=15min
OnUnitActiveSec=1d
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
      fi
      if command -v systemctl >/dev/null 2>&1; then
        systemctl --user daemon-reload || true
        systemctl --user enable --now bvg.service || true
        done_ "systemd-user service draait: bvg.service"
        if [ -f "$UNIT_DIR/bvg-update.timer" ]; then
          systemctl --user enable --now bvg-update.timer || true
          done_ "self-update timer: bvg-update.timer (daily, +random delay)"
        fi
      else
        say "systemd niet beschikbaar — unit-bestand staat in $UNIT_DIR"
      fi
      ;;
    darwin)
      PLIST="$HOME/Library/LaunchAgents/com.appfabriek.bvg.plist"
      mkdir -p "$(dirname "$PLIST")"
      cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.appfabriek.bvg</string>
  <key>ProgramArguments</key><array>
    <string>$BIN_DIR/bvg</string>
    <string>daemon</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/bvg.log</string>
  <key>StandardErrorPath</key><string>/tmp/bvg.err</string>
</dict>
</plist>
EOF
      launchctl unload "$PLIST" 2>/dev/null || true
      launchctl load "$PLIST"
      done_ "launchd-agent geladen: com.appfabriek.bvg"

      # --- Daily self-update launchd-agent (macOS) ---
      if [ -x "$LIB_DIR/bvg-update.sh" ]; then
        UPDATE_PLIST="$HOME/Library/LaunchAgents/com.appfabriek.bvg-update.plist"
        # Random hour between 3-4am to spread API load across clients.
        UH=$((3 + RANDOM % 2))
        UM=$((RANDOM % 60))
        cat >"$UPDATE_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.appfabriek.bvg-update</string>
  <key>ProgramArguments</key><array>
    <string>$LIB_DIR/bvg-update.sh</string>
  </array>
  <key>StartCalendarInterval</key><dict>
    <key>Hour</key><integer>$UH</integer>
    <key>Minute</key><integer>$UM</integer>
  </dict>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>/tmp/bvg-update.log</string>
  <key>StandardErrorPath</key><string>/tmp/bvg-update.err</string>
</dict>
</plist>
EOF
        launchctl unload "$UPDATE_PLIST" 2>/dev/null || true
        launchctl load "$UPDATE_PLIST"
        done_ "self-update launchd-agent geladen: com.appfabriek.bvg-update (daily at ${UH}:$(printf '%02d' $UM))"
      fi
      ;;
  esac
  exit 0
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) say "Add $BIN_DIR to your PATH: export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

say "next step: bvg join --host <bvgeert-host> --token <jt_xxx>"
say "           of (Azure-fallback): bvg join --hub <wss-url> --transport <id> --token <jt_xxx>"
