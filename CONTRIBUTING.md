# Contributing to Porthole

Thanks for helping. This page covers how to find something to work on, what you need to build and test, and the house rules a pull request is reviewed against. Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Find something to work on

- Issues labelled [good first issue](https://github.com/muhammademanaftab/porthole/labels/good%20first%20issue) are small and say where to start.
- Issues labelled [help wanted](https://github.com/muhammademanaftab/porthole/labels/help%20wanted) are bigger, often a new feature.
- Comment on an issue before you start. The first person to comment is assigned, and an assigned issue is taken. This stops two people building the same thing.
- Keep to two open pull requests at a time, so reviews stay quick and others get a turn.
- For a new idea, open an issue first, so we can agree on the shape before you write code.
- Trying Porthole on your own Macs and reporting what broke is a real contribution too. The newest screens have had little use by hand.

## What you need

| To work on | You need |
|---|---|
| The browser viewer (`web/`) | Node 20 or later, on any operating system |
| The shared logic, the `porthole` command, the tests | An Apple Silicon Mac with macOS 14 or later and Swift 5.10 or later (Xcode 15.3 or its Command Line Tools) |
| The app itself | The same, plus `brew install livekit` |

The first build downloads the LiveKit and WebRTC libraries, about 700 MB, so it takes a while.

## Where the code lives

[docs/design.md](docs/design.md) explains every part. The short version:

- `Sources/PortholeCore` is logic with no user interface: messages, pairing, trust, routes, share links, input mapping. Put new logic here when you can, because everything here is unit tested.
- `Sources/PortholeSelfTest` holds the checks for `PortholeCore`. There is one file per area, and `main.swift` calls each one.
- `Sources/PortholeApp` is the app: the host (the Mac you share) and the viewer in one process.
- `Sources/PortholeCLI` is the `porthole` command.
- `web/` is the browser viewer. `porthole-core.js` holds its logic and `web/tests` checks it.

## Run the tests

```sh
scripts/test.sh
```

This runs the Swift checks and the web tests. To run only the web tests:

```sh
node --test web/tests/*.test.js
```

If you changed how the app is built or packaged, also run:

```sh
scripts/bundle.sh && scripts/check-bundle.sh
```

CI runs these for every pull request: the tests on macOS 15 and macOS 26, the web tests on Linux as well, and the bundle checks on macOS 26.

## Try your change

The tests cannot cover capture, typing or the windows themselves, so try those by hand and say in the pull request what you tried.

- **With one Mac:** build the app with `scripts/bundle.sh`, open `dist/Porthole.app`, turn on **Settings › Sharing › Share this Mac**, then open `http://localhost:7878` in a browser on the same Mac. This exercises the host: capture, input, sound, clipboard and share links.
- **With two Macs:** install the app on both and pair them. Changes to pairing, discovery and the viewer's windows need this.
- `PORTHOLE_HOME=/some/folder` runs a second instance with its own settings and pairings, so testing does not touch your real ones. `porthole env` lists every setting.
- `porthole doctor` checks permissions, ports and pairing on the Mac it runs on.

With ad hoc signing macOS asks for Screen Recording and Accessibility again after every rebuild. A self-signed code-signing certificate named "Porthole Dev" in your keychain avoids that (see the README).

## Pull requests

- Branch from `main` and open the pull request against `main`.
- One change per pull request. A bug fix and a refactor are two pull requests.
- Write the title as a plain sentence that says what changed, like the ones in the log (`Rebuild an empty Stage when a viewer with a different screen size connects`). A short area prefix is fine (`README: ...`, `Probe: ...`).
- Link the issue in the description (`Closes #12`).
- Say which Macs and macOS versions you tried it on.

## House rules

Pull requests are reviewed against these, so checking them first saves a round trip:

- **No code comments.** Names and tests carry the meaning.
- **Tests come with the change.** Logic goes in `PortholeCore` with checks in `PortholeSelfTest`. Browser logic goes in `web/porthole-core.js` with tests in `web/tests`. For a bug, add a check that fails before the fix.
- **No new dependencies** without an issue that agrees to them first. Porthole depends on the LiveKit SDK and nothing else.
- **Plain English** in the app, the command output and the docs. No hype words, and no em dashes: use commas, full stops, colons or brackets.
- **Never weaken a security check** to make something easier. Pairing, share links and the guess limits are described in [docs/design.md](docs/design.md); a change there needs its reasoning in the pull request.

## Privacy

Porthole shows people's screens, so nothing real belongs in the repository.

- Never commit real machine names, addresses, passwords, pairing codes or secrets. Tests use made-up names and neutral addresses.
- Check screenshots and logs for the same before you attach them to an issue or a pull request. `porthole report` removes secrets from what it collects, but read it before you share it.
- `scripts/deploy.local` holds your own machine's details and is ignored by git. Keep it that way.
- Security problems go through a private report, not an issue. See [SECURITY.md](SECURITY.md).

## AI-assisted pull requests

Welcome. Say in the description that an AI tool helped, and run the tests yourself before opening it. You are responsible for the change either way.

## Licence

By contributing you agree that your work is released under the [MIT License](LICENSE).
