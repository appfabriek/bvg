# bvg

Public download repo for the **bvg** transport client (a single self-contained
**Dart** binary). Releases worden hier gehost; ontwikkeling gebeurt in
[`appfabriek/bvgeert`](https://github.com/appfabriek/bvgeert) onder `clients/bvg/`.

De client verbindt met het bvgeert-transportnetwerk over **Azure Web PubSub** en
spreekt het verenigde wire-protocol (enroll → keypair-auth → daemon). Hij draait
als service (launchd / systemd-user / Windows-service) en handelt fleet-control
af (`command.status_query`, `command.shell`).

## Aanbevolen: install via de admin-one-liner

In bvgeert: **admin → connectie → "client toevoegen"** geeft één regel die je op
de doelmachine plakt. Die loopt via de installer-proxy (`bvg1.azurewebsites.net`),
die de juiste host + een anonieme Azure-bootstrap-url invult en de installer draait:

```bash
# Linux / macOS
curl -sL https://bvg1.azurewebsites.net/<slot>/<token> | bash
```
```powershell
# Windows (elevated)
iwr https://bvg1.azurewebsites.net/w/<slot>/<token> -useb | iex
```

Dit werkt ook vanaf **restricted netwerken** die bvgeert niet direct kunnen
bereiken: de client haalt zijn Azure-access-url via de proxy op en bootstrapt
puur over Azure.

## Directe install (zonder proxy)

Zet de env-vars en draai `install.sh`/`install.ps1` rechtstreeks. Vereist:
`BVG_JOIN_TOKEN`, `BVG_TRANSPORT` (connectie-identifier) en
`BVG_ANON_BOOTSTRAP_URL` (de proxy-/anon-endpoint voor Azure-access-urls).

```bash
BVG_JOIN_TOKEN=jt_... \
BVG_TRANSPORT=my-connection \
BVG_ANON_BOOTSTRAP_URL=https://bvg1.azurewebsites.net/anon/<slot> \
  bash -c "$(curl -fsSL https://github.com/appfabriek/bvg/releases/latest/download/install.sh)"
```
```powershell
$env:BVG_JOIN_TOKEN          = "jt_..."
$env:BVG_TRANSPORT           = "my-connection"
$env:BVG_ANON_BOOTSTRAP_URL  = "https://bvg1.azurewebsites.net/anon/<slot>"
iwr https://github.com/appfabriek/bvg/releases/latest/download/install.ps1 -UseBasicParsing | iex
```

De installer downloadt de platform-binary (`bvg-linux-x64`, `bvg-macos-arm64`,
`bvg-windows-x64.exe`), enrollt (`bvg enroll`) en installeert de service die
`bvg daemon` draait.

## Commando's

```
bvg enroll   --token <jt> --bootstrap <anon-url> --transport <conn> [--hostname <h>]
bvg daemon   # verbindt + blijft online (door de service gestart)
bvg status   # toont enrollment-staat
```

## Uninstall

Linux/macOS:
```bash
launchctl unload ~/Library/LaunchAgents/nl.bvgeert.bvg.plist 2>/dev/null   # macOS
systemctl --user disable --now bvg.service 2>/dev/null                      # Linux
rm -rf ~/.bvg ~/Library/LaunchAgents/nl.bvgeert.bvg.plist ~/.config/systemd/user/bvg.service
```

Windows (elevated):
```powershell
& "$env:ProgramData\bvg\bvg-svc.exe" stop; & "$env:ProgramData\bvg\bvg-svc.exe" uninstall
Remove-Item -Recurse -Force "$env:ProgramData\bvg"
```
