# porthole

Share single windows from a Mac (the host) to your other machines: as real windows on another Mac, or in a browser tab on any device. Personal tool, built on LiveKit and ScreenCaptureKit.

## Parts

- **Porthole Host** (`porthole-host`): menu-bar app on the Mac whose windows you share. Runs a local LiveKit server, captures windows, recreates input.
- **Porthole** (`porthole-view`): Mac viewer. Each remote window opens as a native window.
- **Browser viewer**: served by the host at `http://<host>:7878/?pw=<password>`.

## Build

Needs macOS 14+ and the Xcode Command Line Tools, plus `brew install livekit`.

```
scripts/test.sh
scripts/bundle.sh          # dist/Porthole Host.app, dist/Porthole.app
```

`scripts/test.sh` runs the Swift self-test (`swift run PortholeSelfTest`) and the browser tests (`node --test web/`).
After bundling, `scripts/check-bundle.sh` verifies bundle ids, bundled web files and code signatures in `dist/`.

Set `SIGN_ID` to a code-signing identity so macOS keeps Screen Recording and Accessibility permissions across rebuilds.

## Use

1. On the host, open Porthole Host and grant Screen Recording and Accessibility.
2. Copy the browser link or password from its menu-bar icon.
3. On another Mac: `open dist/Porthole.app --args <host> <password>`, or open the link in a browser.

Ports: 7878 (web and tokens), 7880 to 7882 (LiveKit).
