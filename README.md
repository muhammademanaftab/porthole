# Porthole

Use another Mac's windows, or its whole screen, from your Mac or a browser.

## Install

```sh
scripts/bundle.sh && cp -R dist/Porthole.app /Applications/
scripts/install-cli.sh
```

On the Mac you share: allow **Screen Recording** and **Accessibility**, turn on **Settings › Share this Mac**.

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
scripts/deploy-mini.sh
```
