<p align="center">
  <img src=".github/DNSwitch-icon.png" width="128" alt="DNSwitch icon">
</p>

# DNSwitch

A native macOS menu-bar app for turning encrypted DNS on and off and switching between providers. Built on AdGuard [dnsproxy](https://github.com/AdguardTeam/dnsproxy); switching takes about a second.

Requires macOS 13 or later.

Supported providers and protocols:

| Provider | DoT | DoH | DoH3 | DoQ |
|---|:---:|:---:|:---:|:---:|
| Google | ✅ | ✅ | ✅ | — |
| Cloudflare | ✅ | ✅ | ✅ | — |
| NextDNS (profile optional) | ✅ | ✅ | ✅ | ✅ |

## Install

1. Download the latest zip from [Releases](../../releases) and move DNSwitch to `/Applications`.
2. Open DNSwitch, click **Install engine** in the menu, and approve it in System Settings when prompted (under App Background Activity).

## How it works

```
┌─ DNSwitch (menu-bar app) ─┐           ┌─ Engine (background service) ─┐
│  settings and status      │  commands │  encrypted DNS resolver       │
│  runs as you              │ ────────► │  manages system DNS settings  │
│  no admin privileges      │ ◄──────── │  runs with admin privileges   │
└───────────────────────────┘   status  └───────────────────────────────┘
```

## Build from source

Requires Xcode, Go 1.26+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The Xcode project is generated from `app/project.yml`.

```bash
brew install xcodegen go
cd app && xcodegen generate
xcodebuild -project DNSwitch.xcodeproj -scheme DNSwitch -configuration Debug build
```

## License

[MIT](LICENSE). DNSwitch includes AdGuard dnsproxy (Apache-2.0) and other open-source components; their licenses are listed in [THIRD-PARTY-LICENSES](THIRD-PARTY-LICENSES) and included in the app bundle.
