<p align="center">
  <img src=".github/DNSwitch-icon.png" width="128" alt="DNSwitch icon">
</p>

# DNSwitch

A native macOS menu-bar app for switching encrypted DNS. It embeds AdGuard [dnsproxy](https://github.com/AdguardTeam/dnsproxy) as a Go library and swaps upstreams in-process, so a switch takes about a second.

Supported DNS providers:

| Provider | DoT | DoH | DoH3 | DoQ |
|---|:---:|:---:|:---:|:---:|
| Google (unfiltered) | ✅ | ✅ | ✅ | — |
| Cloudflare (unfiltered, 1.1.1.1) | ✅ | ✅ | ✅ | — |
| NextDNS (profile optional) | ✅ | ✅ | ✅ | ✅ |

## Install

Download the notarized zip from [Releases](../../releases).

Then click **Install engine** in the menu and approve it in System Settings › App Background Activity. That registers the root daemon that binds `127.0.0.1:53` and rewrites the system resolver.

**Uninstall:** Use **Settings › Engine › Uninstall** first — it turns encryption off, restores your original DNS settings, and unregisters the daemon. Then delete the app.

## Build from source

Requires Xcode, Go 1.26+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (the Xcode project is generated from `app/project.yml`).

```bash
brew install xcodegen go
cd app && xcodegen generate
xcodebuild -project DNSwitch.xcodeproj -scheme DNSwitch -configuration Debug build
```

For a notarized release build, run `./packaging/release.sh` (`--check` for preflight). It never sees your credentials — it references a `notarytool` keychain profile by name; the script's header has the one-time setup. Forks must change `TEAM_ID` and `DEVELOPMENT_TEAM` in `app/project.yml`.

## How it works

```
┌─ DNSwitch.app ──────────────┐        ┌─ com.fx.dnswitch.engine (root) ─┐
│  SwiftUI MenuBarExtra       │  unix  │  embedded dnsproxy → :53        │
│  unprivileged, LSUIElement  │◄──────►│  rewrites system DNS            │
│                             │ socket │  DNS watchdog, state.json       │
└─────────────────────────────┘ NDJSON └─────────────────────────────────┘
```

Only the root daemon touches system DNS. The control socket requires the peer to be the console user **and** validates the client's code signature via its audit token — otherwise any process running as you could turn encryption off.

A crash can't take the machine offline: original resolver values are snapshotted atomically before anything is touched and reconciled on the next start, `launchd` restarts the daemon, and a single-instance `flock` keeps two engines from fighting over your settings.

## Emergency recovery

If system DNS is ever left pointing at `127.0.0.1` with nothing listening:

```bash
sudo networksetup -setdnsservers "Wi-Fi" Empty   # repeat per service from -listallnetworkservices
```

You shouldn't need this — startup reconciliation handles it — but it's the escape hatch.

> Little Snitch / LuLu users: allow the engine's first outbound connection, or the block makes it look like the network died.

## License

[MIT](LICENSE). The engine statically links AdGuard dnsproxy (Apache-2.0) and other modules — all licenses are reproduced in [THIRD-PARTY-LICENSES](THIRD-PARTY-LICENSES) and ship inside the app at `Contents/Resources/`.
