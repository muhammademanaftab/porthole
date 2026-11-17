# Third-party software and media

- **LiveKit Swift SDK** (`client-sdk-swift`, pinned in `Package.resolved`), Apache License 2.0, https://github.com/livekit/client-sdk-swift
- **livekit-client** 2.23.0 (`web/livekit-client.umd.min.js`, unmodified build from npm), Apache License 2.0, https://github.com/livekit/client-sdk-js
- **livekit-server** (not in this repository; `scripts/bundle.sh` copies it into the app from your Homebrew install, and release builds compile it from source with `scripts/build-livekit.sh`, which pins the version), Apache License 2.0, https://github.com/livekit/livekit
- **LiveKit WebRTC** (`LiveKitWebRTC.framework`, a prebuilt WebRTC from `webrtc-xcframework`, pinned in `Package.resolved`, copied into the app), BSD 3-Clause License and the licences of the libraries WebRTC includes, https://github.com/livekit/webrtc-xcframework and https://webrtc.org/support/license
- **LiveKit FFI** (`RustLiveKitFFI.framework`, from `livekit-ffi-xcframework`, pinned in `Package.resolved`, copied into the app), Apache License 2.0, https://github.com/livekit/rust-sdks

The Apache License 2.0 text: https://www.apache.org/licenses/LICENSE-2.0

## Media in the demo video

- **Big Buck Bunny** (a short section plays inside `docs/video/porthole-demo.mp4`), © Blender Foundation, Creative Commons Attribution 3.0, https://peach.blender.org
