# Security

Porthole lets one Mac see and control windows on another, so a flaw here can be serious. This page says how to report one, which versions get fixes, and what Porthole does and does not protect against.

## Reporting a vulnerability

Report it privately through a GitHub security advisory on this repository: open the **Security** tab and choose **Report a vulnerability**, or go straight to [the form](https://github.com/muhammademanaftab/porthole/security/advisories/new). Only the maintainer can read it.

Please do not open a public issue, and do not disclose the problem publicly until a fix is available. Say what you found, how to reproduce it, and which version or commit you tested. Leave real machine names, passwords and pairing codes out of the report.

## Supported versions

Porthole is an early release. Fixes go into `main` and the next release; older releases are not patched.

## What Porthole protects

- **Pairing.** The 6-digit code keys a password-authenticated key exchange, so the code and the pairing secret never cross the network, and someone in the middle gets one guess per code. The host keeps only a hash of the secret; the viewer keeps it in the Keychain.
- **Connecting.** A paired Mac proves itself with its secret, and the host's answer is sealed with it, so a fake host on the network learns nothing. On the local network the viewer also checks a proof from the host before it uses an address.
- **Video, sound, input and clipboard** travel over WebRTC, which is encrypted.
- **Share links.** A link carries a random token and the host stores only its hash. A guest can see only that link's window, can type and click only if the link allows control, and system shortcuts are blocked.
- **Guess limits.** Pairing codes, the browser password and the lock-screen password each have a guess budget that survives a restart.
- **Clipboard.** Items that a password manager marks as private are not synced.

## Known limits

These are how Porthole works today, not vulnerabilities to report:

- **Plain HTTP on port 7878.** Porthole's web page and the connection set-up are not encrypted. On a network you do not trust, someone who can read the traffic could see the browser password or take over a session for a few minutes. Use Tailscale, which encrypts everything between your machines, when you are not at home.
- **The browser password gives full control** of the shared windows. Keep it to yourself and use share links for other people.
- **Release builds are not notarized by Apple.** They are signed ad hoc, so macOS asks you to approve the app on first open. Each release lists a SHA-256 checksum for its download.
- **The host Mac trusts paired Macs fully.** Unpair a Mac you no longer control (**Paired Macs** in the menu, or `porthole unpair`).

The design behind all of this is in [docs/design.md](docs/design.md).
