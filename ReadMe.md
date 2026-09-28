# my-notch

A personal fork of [Atoll](https://github.com/Ebullioscopic/Atoll) (from the
boring.notch family) — the macOS notch app — with an **integrated
mini-browser** living inside the notch.

## Why this fork exists

Atoll turns the MacBook notch into a live surface: media controls, calendar,
shelf, terminal, stats. This fork adds one more tab — a real WebKit browser —
so you can click the notch and land on YouTube (or anywhere) without switching
windows. Built for a primary use case: **watching videos and reading timelines
(X, Reddit) in a panel that drops out of the notch**.

## What's different from upstream Atoll

Everything upstream works unchanged. This fork is strictly additive:

| Area | Addition |
|---|---|
| Browser tab | New "Browser" tab (globe icon) in the notch tab strip |
| Panel sizing | S/M/L/XL presets + a drag handlebar for any height in between |
| Pin & auto-close | Pin keeps the panel open; unpinning re-arms a configurable auto-close timer |
| Session | Tabs + logins persist across app restarts |
| Settings | New "Browser" section (enable, search engine, size, auto-close, force dark mode) |

Zero visual or behavioral changes to any existing Atoll feature.

## Building

Requirements: **Xcode 16+** (built with Xcode 26.6 on macOS 26), plus the
Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`).

```bash
xcodebuild -project DynamicIsland.xcodeproj -scheme DynamicIsland \
  -configuration Debug build \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM=<your-team-id> \
  CODE_SIGN_STYLE=Manual
```

The app bundle lands in
`~/Library/Developer/Xcode/DerivedData/DynamicIsland-*/Build/Products/Debug/Atoll.app`
(the binary keeps the upstream `Atoll` name).

## Docs

- [`BROWSER.md`](BROWSER.md) — the mini-browser: architecture, resize system,
  session persistence, and the gesture-interception story.

## Git layout

- `upstream` → Ebullioscopic/Atoll (pull future updates from here)
- `origin` → this repo
- `dev` → clean upstream dev branch, the baseline
- `feature/browser` → the mini-browser feature

## License & provenance

Atoll is GPL-3.0 (see upstream). This fork inherits that license. The browser
tab's search-engine dispatch and keep-tab-alive pattern reference
[Search](https://github.com/…/Search) (MIT), kept as inspiration only.
