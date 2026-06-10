# bvg

Public download repo for the **bvg** transport client (a single self-contained
**Dart** binary). Releases worden hier gehost; ontwikkeling gebeurt in
[`appfabriek/bvgeert`](https://github.com/appfabriek/bvgeert) onder `clients/bvg/`.

De client verbindt met het bvgeert-transportnetwerk over **Azure Web PubSub** en
spreekt het verenigde wire-protocol. Hij draait als service (launchd /
systemd-user / Windows-service) en handelt fleet-control af (`command.status_query`,
`command.shell`). De client **update zichzelf** over de wire (`update.check` ->
download nieuwe release-binary -> atomic swap -> herstart), ook als hij nog
anoniem (pre-enroll) is.

## Aanbevolen: install via de admin-one-liner

In bvgeert: **admin -> connectie -> "client toevoegen"** geeft een regel die je op
de doelmachine plakt (via de installer-proxy `bvg1.azurewebsites.net`):

```bash
# Linux / macOS
curl -sL https://bvg1.azurewebsites.net/<slot>/<token> | bash
```
```powershell
# Windows (elevated)
iwr https://bvg1.azurewebsites.net/w/<slot>/<token> -useb | iex
```

Werkt ook vanaf **restricted netwerken**: de client haalt zijn Azure-access-url
via de proxy op en bootstrapt puur over Azure.

## Directe install (zonder proxy)

Env-vars + draai `install.sh`/`install.ps1`. `BVG_JOIN_TOKEN` is **optioneel**
(zie tokenloos hieronder); `BVG_TRANSPORT` en `BVG_ANON_BOOTSTRAP_URL` zijn vereist.

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

## Tokenloze (anoniem-eerst) install

Laat `BVG_JOIN_TOKEN` weg. De client wordt geinstalleerd en draait in
**anonieme (pre-enroll) modus**: hij verbindt anoniem over Azure en blijft vers
(self-update), maar wisselt nog geen berichten uit. Enroll later wanneer je een
token hebt:

```bash
BVG_TRANSPORT=my-connection \
BVG_ANON_BOOTSTRAP_URL=https://bvg1.azurewebsites.net/anon/<slot> \
  bash -c "$(curl -fsSL https://github.com/appfabriek/bvg/releases/latest/download/install.sh)"
# later, zodra je een token hebt:
BVG_CREDENTIALS=<creds> bvg enroll --token jt_... --bootstrap https://bvg1.azurewebsites.net/anon/<slot> --transport my-connection
```

## Installeren zonder de service te starten

Zet `BVG_NO_SERVICE=1` (of `-NoService` op Windows). De binary wordt gedownload
en (met token) ge-enrolld, maar er wordt **geen** service geinstalleerd of
gestart; het script print hoe je de daemon handmatig draait:

```bash
BVG_NO_SERVICE=1 BVG_JOIN_TOKEN=jt_... BVG_TRANSPORT=my-connection \
BVG_ANON_BOOTSTRAP_URL=https://bvg1.azurewebsites.net/anon/<slot> \
  bash -c "$(curl -fsSL https://github.com/appfabriek/bvg/releases/latest/download/install.sh)"
# daarna handmatig:
BVG_CREDENTIALS=<creds> BVG_TRANSPORT=my-connection BVG_ANON_BOOTSTRAP_URL=<url> bvg daemon
```

## Commando's

```
bvg enroll   --token <jt> --bootstrap <anon-url> --transport <conn> [--hostname <h>]
bvg daemon   # enrolled: full agent; niet-enrolled: anonieme pre-enroll daemon
bvg launch   # past een pending self-update toe en draait daarna de daemon (service-entrypoint)
bvg status   # enrollment-staat
bvg version  # clientversie
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
