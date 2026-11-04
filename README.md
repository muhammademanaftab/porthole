# Porthole

Share single Mac windows, or the whole screen, to another Mac or a browser.

## How it works

- One app, **Porthole.app**, on every Mac. Every Mac can view; **Share this Mac** (Settings › Sharing) makes it a host.
- The host captures windows with ScreenCaptureKit and streams them over an embedded LiveKit server (HEVC, H.264 for browsers). Viewers send keys, clicks, scrolls and the clipboard back.
- Each shared window opens as its own window on the viewer, with its own Dock icon and ⌘Tab entry.
- Route: same network first (Bonjour), Tailscale otherwise. The portal shows which one.

## Install

```sh
scripts/bundle.sh                 # builds dist/Porthole.app
cp -R dist/Porthole.app /Applications/
scripts/install-cli.sh            # puts `porthole` on the PATH
```

On the host, grant **Screen Recording** and **Accessibility** to Porthole and turn on **Share this Mac**. To update the Mac mini: `scripts/deploy-mini.sh`.

## Use

| Task | How |
|---|---|
| Pair a Mac | Pick the host (padlock), type the 6-digit code it shows. Headless host: `porthole paircode` |
| Open a window | Pick it in the window list |
| Whole screen | The "This Mac's Screen" card (host setting: Off / Ask / Always) |
| Locked host | **Unlock…**, type the login password |
| Browser | `http://<host>:7878`, host password from the menu (Copy Password) |
| Share with someone | Host menu › Share Window… (view-only by default, 24 h) |

## Commands

```sh
porthole doctor            # health check
porthole ls <host>         # windows on a host
porthole open <host> <window>
porthole share [--control] # share link
porthole devices | unpair <id> | paircode
porthole why-quit | trail | log
porthole env               # every PORTHOLE_* flag
```

## Develop

```sh
swift build
scripts/test.sh            # Swift self-tests and web tests
```

| Folder | What |
|---|---|
| `Sources/PortholeCore` | Shared logic (protocol, pairing, routes, policies) |
| `Sources/PortholeHost`, `PortholeView` | Host and viewer roles |
| `Sources/PortholeCLI` | The `porthole` command |
| `Sources/PortholeTile` | Per-window Dock tile helper |
| `Sources/PortholeSelfTest`, `PortholeProbe` | Tests and the headless test client |
| `web/` | Browser viewer |
| `scripts/` | Build, test, deploy |
| `docs/` | Status and design notes |
