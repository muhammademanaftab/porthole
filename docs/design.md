# Porthole: design

Personal tool. Share single windows from a Mac host (the Mac mini `leos-mac-mini`) to
other machines, as real windows (Mac viewer) or a browser tab (Windows laptop, Brave).
Not a product: no accounts, no billing, no App Store.

## Goals (v1)

1. On the host, list shareable windows (titled, on-screen-capable, not ours, not password managers).
2. A viewer picks one; it appears live, sharp (native pixel size, Retina), up to 60 fps.
3. Keyboard, mouse clicks, drags and scroll from the viewer act on that window on the host.
4. Resizing the viewer window resizes the real window on the host.
5. Several windows at once, each its own viewer window or browser tab.
6. Works over Tailscale or LAN.

Non-goals for v1: audio, clipboard, file transfer, Dock icon per window, "move window over",
Windows as a host, whole-screen mode, discovery (viewer is given the host address).

## Architecture

Swift Package (`swift build`, Command Line Tools only, no Xcode), three targets plus tests:

- `PortholeCore` (library): wire protocol, input event model, coordinate mapping. Pure Swift, unit tested.
- `PortholeHost` (menu-bar app, runs on the mini):
  - `WindowCatalog`: ScreenCaptureKit `SCShareableContent` → list of `{id, app, title, w, h}`.
  - `WindowStreamer`: `SCStream` with `SCContentFilter(desktopIndependentWindow:)`, pixel size =
    window points × backing scale, BGRA/NV12 frames → `VTCompressionSession` H.264, real-time,
    no B-frames, keyframe on request and every 2 s.
  - `InputInjector`: keyboard via `CGEvent` `postToPid`; mouse: raise window (AX `kAXRaiseAction`
    + `NSRunningApplication.activate`), then post `CGEvent` at global point mapped from
    normalized (0..1) window coordinates; scroll via scroll-wheel CGEvents. Resize via AX `kAXSizeAttribute`.
  - `Server`: Network.framework `NWListener` with WebSocket protocol on one port (default 7878).
    HTTP GET `/` serves the browser viewer page (embedded resource). Token required (`?t=`).
- `PortholeView` (Mac viewer app, runs on this Mac): connect to `host:port`, show window picker,
  each chosen window = `NSWindow` with `AVSampleBufferDisplayLayer`, sized to remote size; local
  events → input messages; window resize → resize message (debounced).
- Browser viewer (`web/index.html`, plain JS): WebSocket + WebCodecs `VideoDecoder` → canvas.
  Ctrl maps to Cmd for shortcuts.

## Wire protocol

One WebSocket per viewed window plus one control socket for the list. Messages:

- Text (JSON) control: `list` → `{windows:[...]}`; `open {id}`; `input {...}`; `resize {w,h}`;
  `keyframe`; host → `meta {w,h,scale,title}`; `closed`.
- Binary video: `[1 byte type=1][1 byte flags: bit0 keyframe][8 bytes pts µs][Annex-B H.264]`.
  Keyframes carry SPS/PPS inline so any decoder (VideoToolbox, WebCodecs `avc` with
  Annex-B) can start from them.

Backpressure: per-connection send in flight count; if > 2 frames unsent, drop non-key frames
and request a keyframe when caught up. Latest frame wins.

## Security

Bind to all interfaces but require a token (random, stored in host's
`~/Library/Application Support/Porthole/token`, shown in the menu). Traffic is encrypted by
Tailscale; on plain LAN it is not (accepted for personal use).

## Errors

- Missing Screen Recording / Accessibility permission: menu shows it and opens System Settings.
- Window closed on host: stream sends `closed`, viewer window closes with a note.
- Disconnect: viewer retries every 2 s, keeps last frame visible.
- Headless host with no display: documented need for HDMI dummy plug.

## Signing

Self-signed code-signing certificate "Porthole Dev" in the login keychain so TCC grants persist
across rebuilds. `scripts/bundle.sh` builds `.app` bundles with Info.plist and signs them.

## Testing

- Unit (`swift test`): protocol encode/decode, coordinate mapping, key code mapping JS→mac.
- Local end-to-end on this Mac: run host, open a TextEdit window with known text, connect a
  headless test client, assert frames decode at expected size, send keystrokes, assert TextEdit
  content changed (AppleScript).
- Browser: open viewer page in Brave/Playwright against local host, check canvas renders.
- Real: Windows laptop Brave → mini; this Mac viewer → mini.
