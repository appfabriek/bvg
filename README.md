# bvg

Public download repo for the **bvg** transport client. Source en releases
worden hier alleen gehost; ontwikkeling gebeurt in
[`appfabriek/bvgeert`](https://github.com/appfabriek/bvgeert) onder
`clients/bvg/`.

## Install — Linux / macOS

```bash
BVG_JOIN_TOKEN=jt_... \
BVG_BVGEERT_HOST=https://bvgeert.com \
BVG_TRANSPORT=my-connection \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/appfabriek/bvg/main/install.sh)"
```

## Install — Windows (elevated PowerShell)

```powershell
$env:BVG_JOIN_TOKEN   = "jt_..."
$env:BVG_BVGEERT_HOST = "https://bvgeert.com"
$env:BVG_TRANSPORT    = "my-connection"
iwr https://raw.githubusercontent.com/appfabriek/bvg/main/install.ps1 -UseBasicParsing | iex
```

Het script self-elevateert via UAC op Windows. Voor Linux/macOS draait
de daemon onder de huidige user (`systemd --user` / `launchd`-agent).

## Uninstall

Linux/macOS:

```bash
systemctl --user disable --now bvg.service bvg-update.timer
rm -rf ~/.local/lib/bvg ~/.local/bin/bvg ~/.config/bvg ~/.local/state/bvg \
       ~/.config/systemd/user/bvg*.service ~/.config/systemd/user/bvg*.timer
```

Windows:

```powershell
& "$env:ProgramData\bvg\uninstall.ps1"
```

## Releases

Zie [`releases`](https://github.com/appfabriek/bvg/releases) — elke
release bevat:

| Asset | Wat |
|---|---|
| `bvg-windows-x64.zip` + `.sha256` | Self-contained Windows-x64 exe met installer-scripts |
| `bvg.js` + `.sha256` | Bundled Node-CLI (Linux/macOS) |
| `bvg-update.sh` | Self-updater (Linux/macOS) |
| `version.txt` | Plain-text version (gebruikt door updater) |
