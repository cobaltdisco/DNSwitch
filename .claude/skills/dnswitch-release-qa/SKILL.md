---
name: dnswitch-release-qa
description: DNSwitch only. Run the full pre-release QA for the DNSwitch macOS app in this repository before packaging/release.sh. Use when the user asks to release, package or ship a new DNSwitch version. Not for any other project or a generic "run tests" request.
---

# DNSwitch pre-release QA

The QA itself lives in the owner's private `docs/qa/` (a separate repository
nested at `docs/`). This skill drives it, adds the parts only Claude can do
(browser checks, visual review), and ends in GO or NO-GO. `packaging/release.sh`
refuses to run without a GO for the current commit.

## 0. Preconditions — stop if any fails

- The working directory is the DNSwitch repository: `app/project.yml`,
  `packaging/release.sh` and `docs/qa/run.sh` all exist. Otherwise say this
  skill is DNSwitch-only and stop.
- `sudo -n /usr/local/libexec/dnswitch-qa/dnswitch-qa-helper version` works.
  Otherwise ask the user to review and run `sudo docs/qa/helper/install.sh`.
- `docs/qa/restore.sh --check` reports no open snapshot from an earlier run
  (if it does, run `docs/qa/restore.sh` first and report what it restored).
- Both repositories are committed (`git status`, `git -C docs status`); the
  QA report is only valid for a clean HEAD.
- Tell the user: about 45 minutes; the system DNS will be switched and the
  engine restarted (brief network blips); for about 10 minutes the mouse moves
  on its own — please don't use the mouse then. Then proceed.

## 1. Scripted QA

Run `docs/qa/run.sh --profile release` (use `full` when asked, or for a new
major version, a dnsproxy major update, or changes to pinning/uninstall) in the
background and wait for it. It builds the release candidate, snapshots the
machine, runs T0–T5 and L01–L03, restores the machine and prints one summary
line plus the failing checks. Read only that output and, when needed, single
check logs in `dist/qa/<run>/logs/` — never whole files.

If it died or was interrupted: `docs/qa/restore.sh`, then investigate.

## 2. Browser checks (Claude in Chrome)

Work in a new tab. Never type or paste ids, IPs or page contents that include
them into records. For each check:
`docs/qa/browser.sh prepare <provider> <protocol>` → look → `docs/qa/run.sh record <ID> pass|warn|fail "<what you saw>"`.
When all are done: `docs/qa/browser.sh done` (restores the machine).

- B00 — Chrome's Settings › Privacy and security › Security › "Use secure DNS"
  and iCloud Private Relay: if either is on, the browser bypasses the system
  DNS; record `warn` and mention it to the user. Otherwise `pass`.
- B01 — `prepare cloudflare doh`, open https://1.1.1.1/help: "Using DNS over
  HTTPS (DoH)" must be Yes. Then `prepare cloudflare dot`: "Using DNS over TLS
  (DoT)" must be Yes.
- B02 — `prepare nextdns doh3`, open https://test.nextdns.io: status ok and
  protocol DOH3.
- B03 — with `prepare cloudflare doh`, run the extended test on
  https://www.dnsleaktest.com: every resolver listed must belong to Cloudflare.
- B04 — with the user's own selection restored (`browser.sh done`), load a few
  everyday sites (e.g. apple.com, github.com, wikipedia.org): all must load.

## 3. Visual review (V05)

Hand the screenshots in `dist/qa/<run>/shots/t5/` to a sub-agent (images use
a lot of context): tell it what each set should show (see the V03 sets in
`docs/qa/checks/t5.sh`), that black boxes are intentional redaction, and to
report clipping, overlap, contrast, mixed languages, raw keys and wrong
states, ending with PASS or FAIL. Record its verdict with
`docs/qa/run.sh record V05 …`.

If the run lists baseline changes (new or different screenshots, performance
changes), show the user `dist/qa/<run>/shots/t5/index.html` and the
sub-agent's notes and ask. Only after the user agrees:
`docs/qa/run.sh accept dist/qa/<run> V03` (and `L01,L02,L03` for performance).

## 4. Verdict

`docs/qa/run.sh report dist/qa/<run>` rebuilds `result.json` and
`report.html`. Tell the user GO or NO-GO first, then the blocking failures,
warnings, anything restore.sh flagged, and the report path.

On GO the user runs `packaging/release.sh` themselves. Never run it (beyond
`--check`), never notarize, never push or publish. Don't commit anything after
the QA run either: the GO is only valid for the commit it tested.

## Rules

- Private ids (NextDNS / Control D / AliDNS, device names) never appear in any
  output, record, screenshot or commit; outputs are redacted by the scripts —
  don't work around that (e.g. never `defaults read com.fx.dnswitch`).
- No `sudo` except the helper; no changes to System Settings; never disconnect
  the network; only Developer ID builds go into /Applications (the scripts
  enforce this).
