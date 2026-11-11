# Porthole: design

Porthole shares single windows (or a whole screen) from one Mac, the host, to viewers: another Mac running Porthole, or a browser.

## Parts

One Swift package, built with `swift build`:

| Target | What it is |
|---|---|
| `PortholeCore` | Pure logic with no UI: messages, pairing, trust, routes, share links, input mapping, the watchdog's rules. Everything here is unit tested. |
| `PortholeApp` | `Porthole.app` (executable `porthole-host`). The viewer and the host run in one process; hosting is behind **Share this Mac**. |
| `PortholeCLI` | The `porthole` command: diagnostics, logs, share links, and hand-offs to the app. |
| `PortholeTile` | A tiny helper app per open portal, so each shared window has its own Dock icon and Cmd-Tab entry. |
| `VirtualDisplayBridge` | Objective-C declarations for the virtual display used on headless Macs. |
| `PortholeSelfTest` | The test runner (`scripts/test.sh`). |
| `PortholeProbe` | A headless viewer for manual end-to-end checks. |

`web/` holds the browser viewer: `index.html`, `porthole-core.js` (logic shared with its tests) and the LiveKit browser client.

## Host

- **Capture.** ScreenCaptureKit captures each shared window on its own stream, at native pixel size. Frames are published as a LiveKit video track named after the window ID, HEVC for Macs with an H.264 backup for browsers. If encoding gets too slow the capture scale steps down and recovers later.
- **Stage.** Windows a viewer opens are moved to a virtual display (the Stage) sized to the viewer's screen, so they can be any size and stay out of the way. On a Mac with no screen the Stage also stands in as the main display. It is released ten minutes after the last window closes.
- **Input.** Keys, text, clicks and scrolling arrive as small JSON messages on a LiveKit data channel and are posted as system events. Mouse points are clamped to the window. Resizing uses Accessibility.
- **Sound and clipboard.** Sound from the shared apps is mixed into one audio track. Text on the clipboard is synced both ways, up to 1 MB, skipping password-manager items.
- **Whole Mac.** A display can be shared like a window, with an optional privacy curtain that hides the physical screens and blocks local input.
- **Servers.** The app runs a bundled `livekit-server` on port 7880 and a small HTTP server on port 7878 that serves the browser page, hands out room tokens and answers pairing.
- **Watchdog.** A launch agent registered with ServiceManagement runs the same binary in watchdog mode. It reads a heartbeat file and relaunches the app after a crash or a hang, but not after a normal quit.

## Viewer

- **Finding hosts.** Bonjour (`_porthole._tcp`) on the local network, and `tailscale status` across networks. For a paired host the viewer tries the same-network address first and falls back to the saved or Tailscale address.
- **Portals.** Each opened window is an `NSWindow` showing the video track. Local events become input messages. Dialogs and panels of the shared app open as their own small portals.
- **Reconnecting.** A lost connection is retried with a growing delay, and open portals come back by themselves.

## Trust

- **Pairing.** The host shows a 6-digit code. Viewer and host run a password-authenticated key exchange (SPEKE over P-256) keyed by the code and the viewer's device ID, so the code never crosses the network and a man in the middle gets one guess per code. The host then sends a random device secret sealed under the exchanged key. The host keeps only a hash of it; the viewer keeps it in the Keychain.
- **Tokens.** To connect, a paired viewer sends its device ID, a fresh nonce and an HMAC keyed by the secret's hash. The host answers with the LiveKit URL and a ten-minute room token, sealed under a key derived from the same hash and nonce. The viewer refuses any answer it cannot open.
- **Same-network proof.** Before using an address it found on the local network, the viewer asks `/hello` with a nonce and checks an HMAC that covers the address, so another machine cannot pose as the host there.
- **Browser password.** Browsers use the host password from the menu. Wrong guesses are throttled per source address.
- **Share links.** A link carries a random token; the host stores only its hash. Guests get LiveKit track permissions for their window alone, their input is dropped unless the link allows control, and then keys are typed only while that window has the keyboard.
- **Limits.** The host keeps guess budgets for pairing codes, browser passwords and the lock-screen password, and they survive a restart.

Port 7878 and LiveKit signalling are plain HTTP and WebSocket. Media and data are encrypted by WebRTC. Across untrusted networks Porthole is meant to run over Tailscale.

## Files

Everything lives in `~/Library/Application Support/Porthole` (config, pairings, share links, markers; private files are mode 0600) and `~/Library/Logs/Porthole`. `porthole doctor` reads them, and `porthole report` zips them with secrets removed.

## Testing

- `scripts/test.sh` runs the Swift checks and the web tests.
- `scripts/check-bundle.sh` checks a built `dist/Porthole.app`.
- `scripts/check-deploy-restore.sh` simulates failures in the deploy script's rollback.
- Input and capture are tested on a real second Mac; tests on the Mac you work on never inject input.
