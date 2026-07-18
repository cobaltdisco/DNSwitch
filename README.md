# DNSwitch

A native macOS menu-bar app for switching encrypted DNS — protocol and provider — from the menu bar, with **no perceptible restart**. It embeds AdGuard [dnsproxy](https://github.com/AdguardTeam/dnsproxy) as a Go library and swaps upstreams in-process, so a switch takes about a second and in-flight queries keep resolving.

Click the menu bar icon → pick a provider → pick DoT / DoH / DoH3 / DoQ. That's the whole interaction.

## Status

**v0.3** — feature-complete for daily use: signed with a Developer ID, notarized and stapled, shipped as a Universal binary (Apple Silicon + Intel). It has been the author's daily driver across network changes, VPNs, sleep/wake, and reboots.

Not done yet: an in-app update check, a "pause / go direct" mode for captive portals, DMG packaging, log rotation.

## Supported providers

Every combination below was verified against the live resolvers, not just read off documentation.

| Provider | DoT | DoH | DoH3 | DoQ |
|---|:---:|:---:|:---:|:---:|
| Google (unfiltered) | ✅ | ✅ | ✅ | — |
| Cloudflare (unfiltered, 1.1.1.1) | ✅ | ✅ | ✅ | — |
| NextDNS (with or without a profile) | ✅ | ✅ | ✅ | ✅ |

Google and Cloudflare don't offer DoQ, so that slot is simply absent in the UI rather than shown as a broken option.

**A NextDNS profile ID is optional.** Leave it empty and you get NextDNS's free config-less public resolver — no filtering, no logging, no device reporting. Fill it in and your profile's filtering, logging, and device name apply. An optional device name lets NextDNS group logs per machine.

## Install

Download the notarized `DNSwitch-<version>.zip` from [Releases](../../releases), unzip, and drag `DNSwitch.app` to `/Applications`.

Because the build is notarized and stapled, it opens normally on first launch — no `xattr -d`, no right-click → Open — and it works on a machine that has never seen it and is offline.

`/Applications` isn't cosmetic here: `SMAppService` refuses to register a background service from a translocated or non-standard location.

On first launch the menu shows a single **Install background service** button. Approving it in System Settings › General › Login Items registers a root LaunchDaemon (`com.fx.dnswitch.engine`) — the part that can actually bind `127.0.0.1:53` and rewrite the system resolver.

### Uninstall

Deleting the app does **not** remove the background service — launchd keeps the registration. Use **Settings › Background service › Remove** first. That turns encryption off, restores your original DNS settings, and unregisters the root helper, in that order. Then delete the app.

## Build from source

Requires Xcode (with a macOS SDK), Go 1.26+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) — the Xcode project is generated from `app/project.yml` and is not checked in.

```bash
brew install xcodegen go
cd app && xcodegen generate
xcodebuild -project DNSwitch.xcodeproj -scheme DNSwitch -configuration Debug build
```

`packaging/build-engine.sh` builds the Go engine, embeds it at `Contents/MacOS/dnswitch-engine`, and signs it as a pre-sign build phase — nested code must be signed before the outer bundle seal, or the seal breaks.

To produce a notarized release build:

```bash
./packaging/release.sh --check   # preflight: certificate, notary profile, toolchain
./packaging/release.sh           # build → sign → notarize → staple → dist/DNSwitch-<version>.zip
```

`release.sh` never sees your credentials — it references a `notarytool` keychain profile by name. See [docs/09](docs/09-公证与分发.md) for the one-time setup. If you fork this, change `TEAM_ID` and `DEVELOPMENT_TEAM` (in `app/project.yml`) to your own.

## How it works

Two processes, deliberately:

```
┌─ DNSwitch.app ──────────────┐        ┌─ com.fx.dnswitch.engine (root) ─┐
│  SwiftUI MenuBarExtra       │  unix  │  embedded dnsproxy → :53        │
│  unprivileged, LSUIElement  │◄──────►│  rewrites system DNS            │
│                             │ socket │  DNS watchdog, state.json       │
└─────────────────────────────┘ NDJSON └─────────────────────────────────┘
```

The UI can't change system DNS and doesn't try; only the daemon can, which is why the daemon owns the system-DNS lifecycle end to end. The two talk over `/var/run/dnswitch.sock` with a small versioned NDJSON protocol.

That socket is not merely uid-checked. The daemon requires the peer to be the **console user** and validates the client's code signature through its audit token — otherwise any process running as you could silently turn encryption off.

Three independent safety nets keep a crash from taking the machine offline: the original resolver values are snapshotted and atomically persisted before anything is touched (then reconciled on next start), `KeepAlive` restarts the daemon, and there's a documented manual recovery path. A single-instance `flock` guarantees two engines can never fight over your DNS settings — notably, binding `:53` is *not* a lock, because dnsproxy sets `SO_REUSEPORT`.

The app is **not** sandboxed, on purpose: a sandboxed process cannot connect to a root-owned Unix socket. That rules out the Mac App Store, so Developer ID is the only distribution path.

## Emergency recovery

If the daemon dies in a way that leaves system DNS pointing at `127.0.0.1` with nothing listening, name resolution stops machine-wide. Restore DHCP per network service:

```bash
networksetup -listallnetworkservices             # list service names
sudo networksetup -setdnsservers "Wi-Fi" Empty   # repeat for other services
```

You shouldn't need this — the engine reconciles against its persisted snapshot on startup — but it's the escape hatch if you do.

> Running Little Snitch or LuLu? The engine's first outbound connection to an encrypted upstream triggers a block prompt, and since DNS already points at `127.0.0.1`, it looks like the network died. Allow the engine.

## Documentation

Design and decision records live in [`docs/`](docs/). **They are written in Chinese** — they are the working engineering record (architecture rationale, protocol design, advisor reviews, per-phase acceptance), kept in the language they were produced in.

| Doc | Contents |
|---|---|
| [01 · Architecture](docs/01-技术评估与架构方案.md) | Engine selection (dnsproxy vs ctrld vs off-the-shelf apps), why Swift front end + Go daemon, macOS privilege model, risk register |
| [03 · Decision record](docs/03-产品决策清单.md) | Every settled product/technical decision, with status and an append-only change log (§N) |
| [04 · Provider testing](docs/04-加密DNS供应商与协议实测.md) | The provider × protocol matrix, upstream URL templates, reproducible commands |
| [06 · Control protocol](docs/06-阶段1接口设计.md) | Socket NDJSON protocol, in-process switch sequencing, authentication, concurrency interlocks |
| [07 · Service design](docs/07-阶段2服务化设计.md) | SMAppService registration, console-user + audit-token auth, DNS watchdog, state persistence |
| [08 · Regression checklist](docs/08-验收回归清单与构建指南.md) | Full on-device regression checklist, build/install/second-machine testing |
| [09 · Notarization](docs/09-公证与分发.md) | Developer ID, hardened runtime, notarization, stapling, Universal builds |

## License

DNSwitch is [MIT licensed](LICENSE).

DNS resolution is done by [AdGuard dnsproxy](https://github.com/AdguardTeam/dnsproxy) (Apache-2.0), statically linked into the engine daemon; DNSwitch is the macOS front end and privileged service around it. Every module the engine links, with its license reproduced in full, is listed in [THIRD-PARTY-LICENSES](THIRD-PARTY-LICENSES) — regenerate it with `packaging/gen-third-party-licenses.sh`, which enumerates what the linker actually embedded rather than what `go.mod` mentions. Both files also ship inside the app at `Contents/Resources/`, since that's what users of the notarized build actually receive.
