# Third-party components

pi for iOS bundles or builds on the following. Each keeps its own license; see the linked projects for the full texts.

| Component | Use | License |
| --- | --- | --- |
| [pi](https://github.com/badlogic/pi-mono) (`@earendil-works/pi-ai`, `pi-coding-agent`, `pi-tui`, `pi-mcp`), `pi-durable`, `chord` | the agent and its harness | MIT |
| [a-Shell](https://github.com/holzschu/a-shell) and [ios_system](https://github.com/holzschu/ios_system) | the shell's commands | BSD 3-Clause |
| [dash for iOS](https://github.com/holzschu/dash_iOS) (patched, `Vendor/patches`) | the shell | BSD 3-Clause |
| [curl](https://curl.se) (`curl_ios`) | the shell's `curl` | curl (MIT-style) |
| [libgit2](https://libgit2.org) (`lg2`) | the shell's `git` | GPL-2.0 with the linking exception |
| [OpenSSL](https://www.openssl.org) | curl and lg2 | OpenSSL / SSLeay |
| [libssh2](https://libssh2.org) | lg2 | BSD 3-Clause |
| [CPython](https://www.python.org) via [Python-Apple-support](https://github.com/beeware/Python-Apple-support) | Python | PSF License; BSD 3-Clause |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) (patched, `Vendor/patches`) | on-device models | MIT |
| [esbuild](https://esbuild.github.io) (WebAssembly) | the extension runtime's transpiler | MIT |
| npm packages bundled into the engine (`engine/package-lock.json`): the provider SDKs (OpenAI, Anthropic, Google), TypeBox, yaml, marked, semver, es-module-lexer and others | the engine | their own licenses, mostly MIT and Apache-2.0 |
| Swift packages (`PiEngineKit/Package.resolved`) | native services | their own licenses, mostly Apache-2.0 and MIT |
