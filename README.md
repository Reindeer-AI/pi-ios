# pi for iOS

**An iOS app that wraps [pi](https://pi.dev), the coding agent by [Earendil Works](https://github.com/earendil-works).**
It runs pi's own npm packages on iPhone and iPad: [`pi-coding-agent`](https://www.npmjs.com/package/@earendil-works/pi-coding-agent), [`pi-ai`](https://www.npmjs.com/package/@earendil-works/pi-ai), [`pi-durable`](https://www.npmjs.com/package/@earendil-works/pi-durable),
[`pi-tui`](https://www.npmjs.com/package/@earendil-works/pi-tui), [`pi-mcp`](https://www.npmjs.com/package/@earendil-works/pi-mcp) and [`chord`](https://www.npmjs.com/package/@earendil-works/chord) (source: [earendil-works/pi](https://github.com/earendil-works/pi)).
pi and its packages are Earendil Works'; this app is an independent project by Reindeer AI.

Each session is its own pi agent with its own workspace on the device: a shell, Python, git, a browser, extensions and
their apps, and on-device models, with any model provider you sign in to.

## What it does

- **Sessions** that keep working in the background, resume after the app is closed, compact their context the way pi
  does, and can be forked, shared as a file (`.pisession`) and opened on another device.
- **Tools on the device**: a POSIX shell with common Unix tools, curl and git; CPython with pip (pure-Python wheels);
  a browser the agent can drive; files and images it can read.
- **Models**: pi's providers (sign in or add an API key), any OpenAI-compatible server (Ollama on a Mac, a gateway), and
  on-device models through llama.cpp.
- **Extensions and skills**, as in pi: install them from GitHub, npm, git or a file, or let the agent write them (it
  asks before adding one from the internet). Every extension's source can be read and changed in Settings. An
  extension can bring an **app**: a page that stays open beside the session, minimized to its dock. Extensions can use
  the camera, microphone and location once you allow each one.
- **MCP servers**, **Shortcuts** ("Ask pi"), attachments, dictation.
- **A vault** for card and document numbers, behind Face ID: extensions and the agent see each item's name, and use its
  values only after you allow it.
- **iCloud Keychain sync** of sign-ins, settings, extensions and the vault across your devices.

## How it works

The agent is [pi](https://github.com/earendil-works/pi)'s, running on its durable harness (`@earendil-works/pi-durable`)
inside a hidden WKWebView (`engine/`). The app (`App/`, SwiftUI) and its native services (`PiEngineKit/`) give the engine
what a browser page can't have: the shell ([a-Shell](https://github.com/holzschu/a-shell)'s `ios_system` and a patched
dash), CPython ([BeeWare's Python-Apple-support](https://github.com/beeware/Python-Apple-support)), SQLite for the
durable store, the network, the Keychain, and a llama.cpp server for on-device models (`Vendor/`).

```
App/            the iOS app (SwiftUI): sessions, settings, the browser, apps, the vault
PiEngineKit/    native services the engine calls: shell, files, SQLite, network proxy, Keychain, vault, MCP, GitHub
engine/         the agent: pi's packages bundled for WebKit, with the app's tools, extension runtime and commands
Vendor/         scripts that fetch or build the native components (a-Shell's commands, dash, CPython, llama.cpp)
extensions/     example extensions (with apps): flights, gmail, personal details
tools/          UI tests (DemoTour) and small test servers
scripts/        build-ipa.sh: a signed .ipa
```

## Building

You need a Mac with Xcode 26, Node 22 and Homebrew's `automake`. pi runs on iOS and iPadOS 26 or later.

```sh
# Native components (once; they go to Vendor/, which git ignores)
Vendor/fetch-ashell.sh
Vendor/fetch-python.sh
Vendor/build-dash.sh
Vendor/build-llama.sh

# The engine (again after changing engine/)
cd engine && npm ci && npm run build && cd ..

open App/PiMobile.xcodeproj
```

Run the PiMobile scheme on a simulator. For a device, choose your team in Signing & Capabilities and a bundle identifier
of your own. A signed `.ipa`: `PI_TEAM=<your team id> scripts/build-ipa.sh` (see the script for profiles).

## Tests

`tools/DemoTour` holds XCUITest flows over the real app (sessions, extensions and apps, the vault, Shortcuts, sync,
compaction). Most of them talk to a model: set one up in the simulator's pi first (a provider, or a network server).

## Contributing

Issues and pull requests are welcome. Keep changes small and focused, match the surrounding code, and say how you tested
them.

While this repo is mostly clanker slop, contributions from clankers are not welcome, and will get you blocked if they're
slop.

## License

MIT, © Reindeer AI. Third-party components and their licenses: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Privacy

pi collects nothing: [PRIVACY.md](PRIVACY.md), the app's privacy policy.
