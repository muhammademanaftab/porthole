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
After bundling, `scripts/check-bundle.sh` verifies bundle ids, icons, bundled web files and code signatures in `dist/`.

The app icons in `assets/` are drawn in code: `swiftc scripts/make-icons.swift -o /tmp/make-icons && /tmp/make-icons assets` redraws them.

Set `SIGN_ID` to a code-signing identity so macOS keeps Screen Recording and Accessibility permissions across rebuilds.

## Use

1. On the host, open Porthole Host and grant Screen Recording and Accessibility.
2. Copy the browser link or password from its menu-bar icon.
3. On another Mac: open Porthole. The Connect window lists hosts found with Bonjour (same network) and Tailscale (online macOS peers answering `/hello`). A host this Mac hasn't paired with shows a padlock; picking it asks that host to show a 6-digit code on its screen (valid 2 minutes, single use, 5 tries). Type the code once and this Mac may view that host from then on, with no password. Pairing is one way. `open dist/Porthole.app --args <host> <password>` still works, or open the link in a browser.

## Pairing

Trust is per Mac. Each Mac has a device ID in `~/Library/Application Support/Porthole/identity.json`. The host keeps the Macs paired with it in `paired.json` (0600, secrets stored as SHA-256); the viewer keeps each host's secret in the Keychain. The host menu has Pair a New Viewer… (a code for whoever types it first) and Paired Macs… (Unpair removes a Mac and disconnects it at once). The viewer only sends a host's secret to the address it paired at. A request never replaces another Mac's pending code, and every 10 wrong codes pause pairing (1 minute, doubling up to a day; kept in `pairing-budget.json` across restarts). Viewer tokens last 10 minutes; messages from an unpaired Mac are ignored and it is disconnected. Pairing needs this version of the viewer: `/pair` no longer hands out the password. The CLI talks to the running host on 127.0.0.1 with the per-launch secret in `local-secret` (0600).

```
porthole-host paircode          # the code a Mac is waiting for, or a fresh one; works over SSH on a Mac with no screen
porthole-host devices           # this Mac's device ID and the Macs paired with it
porthole-host unpair <name|id>  # it loses access immediately
porthole-view request <host>    # ask the host to show a code for this Mac
porthole-view pair <host> <code>
```

Run them from the app bundles (`"/Applications/Porthole Host.app/Contents/MacOS/porthole-host" paircode`) so the Keychain recognises the binary. Pairing requests also print their code to the host's standard output; `PORTHOLE_PAIR_HEADLESS=1` prints it without opening the window. `PORTHOLE_HOME` moves the host's and viewer's state folder (for a second, isolated instance).

## Keep running

Porthole Host's Settings… (⌘, in its menu) has "Keep Porthole Host running on this Mac", on by default. It registers a launch agent with ServiceManagement (`Contents/Library/LaunchAgents/io.github.muhammademanaftab.porthole.watchdog.plist`, shown in System Settings > General > Login Items as Porthole Host). The agent runs the host binary with `watchdog`, a small loop with no UI that:

- opens the host at login,
- relaunches it when it disappears without saying why (`crash`),
- samples and then kills and relaunches it when its main thread stops writing `~/Library/Application Support/Porthole/heartbeat` for 60 s (`hang`; the sample goes to `~/Library/Logs/Porthole/hang-<time>.txt`; `PORTHOLE_WATCHDOG_HANG_SECS`, at least 15),
- relaunches it right away after a Mac with one of its windows open chooses Restart Host in Porthole's app menu (`remote`),
- relaunches it when it quit for a logout, shutdown or outside quit (Activity Monitor, `osascript`) and is still missing 45 s later (`missingAfterQuit`).

Each launch is logged in `~/Library/Logs/Porthole/host.log` as `watchdog relaunch reason=<reason>`. Quit from the menu means stay quit: the watchdog leaves it stopped until you open it again or restart the Mac. Turning the switch off unregisters the agent; the host keeps running. `PORTHOLE_WATCHDOG=0|1` decides for one run whether the watchdog watches this host, without registering, unregistering or changing the saved switch. The old `~/Library/LaunchAgents/io.github.muhammademanaftab.porthole.plist` is booted out and deleted on first launch.

Ports: 7878 (web and tokens), 7880 to 7882 (LiveKit).

## Picture

Windows are published as H.265 with an H.264 backup. LiveKit hands the backup to viewers that can't decode H.265; while one of them watches a window, every viewer of that window gets H.264 until it is opened again. The capture scale steps down 2, 1.5, 1.25, 1 when encoding a moving window costs more than 30 ms a frame or the encoder falls behind, never within 10 s of input, and climbs back after 45 s. While a window moves or receives input the last frame is re-sent at the stream rate, and once it goes quiet it gets one refresh after 3 s and a keepalive every second.

The open message may carry `bitrate` (kbps, 1000 to 100000), `fps` (30, 60 or 120) and `level` (top capture scale: 1, 1.25, 1.5 or 2); the viewer that starts a window's stream sets them. `PORTHOLE_ENCODE_LOG=1` logs each encoder sample and `PORTHOLE_ENCODE_BUDGET_MS` changes the budget.
