# Porthole

Use another Mac's windows, or its whole screen, from your Mac or a browser.

## Requirements

- An Apple Silicon Mac with macOS 14 or later.
- Swift 5.10 or later (Xcode 15.3 or its Command Line Tools).
- `brew install livekit` (the server is copied into the app).
- Node 20 or later, only for the web tests.

## Install

```sh
scripts/bundle.sh && cp -R dist/Porthole.app /Applications/
scripts/install-cli.sh
```

`install-cli.sh` links `porthole` into `~/bin` or `/usr/local/bin`; pass `--dir DIR` for another folder on your PATH.

On the Mac you share: allow **Screen Recording** and **Accessibility**, turn on **Settings › Sharing › Share this Mac**.

The app is signed with a certificate named "Porthole Dev" if your keychain has one, and ad hoc otherwise. With ad hoc signing macOS asks for the two permissions again after every rebuild.

## Use

- **Pair:** pick the Mac, type the 6-digit code it shows.
- **Open a window:** pick it from the list.
- **Whole screen:** pick "This Mac's Screen".
- **Locked Mac:** click **Unlock…**, type its password.
- **Browser:** `http://<mac>:7878` with the password from the menu.
- **Share a link:** menu › Share Window….

## Commands

```sh
porthole doctor     # check everything
porthole ls <mac>   # list windows
porthole share      # make a link
porthole env        # all settings
```

## Develop

```sh
swift build
scripts/test.sh
scripts/deploy.sh   # install on another Mac; see --help
```
