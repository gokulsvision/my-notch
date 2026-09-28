# The Notch Mini-Browser

A WebKit browser that lives in an Atoll notch tab. This document explains how
it works — architecture, the resize system, session persistence, and the
non-obvious parts (gesture interception, hover-close integration).

## Files

| File | Role |
|---|---|
| `DynamicIsland/components/Browser/WebPage.swift` | `NSViewRepresentable` wrapping a persistent `WKWebView` (SwiftUI has no native wrapper on macOS) |
| `DynamicIsland/components/Browser/WebTab.swift` | One tab = one lazily-created `WKWebView`, kept alive when hidden; search-engine dispatch |
| `DynamicIsland/components/Browser/WebTabsModel.swift` | Tab list (max 4), active tab, address bar state, zoom, session save/restore |
| `DynamicIsland/components/Browser/BrowserView.swift` | Chrome: tab strip, omnibox, nav/zoom/pin buttons, page area, drag handlebar |

## Core design decisions

### One persistent WKWebView per tab

SwiftUI recreates views aggressively; recreating a `WKWebView` reloads the
page and drops session state. So each `WebTab` owns **one** webview for its
whole lifetime and `WebPage` merely re-binds the existing instance into the
view tree (`makeNSView` returns it; `updateNSView` does nothing). Hidden tabs
stay alive off-screen — switching tabs never reloads anything.

Tabs are capped at 4. Opening a 5th recycles the oldest non-active tab
(destroying its webview), matching the keep-tab-alive pattern without
unbounded memory.

The model lives on a shared singleton (`WebTabsModelHolder`), so it outlives
individual SwiftUI view lifecycles — the notch can close, reopen, and switch
tabs without the browser forgetting anything.

### Keep-alive across notch open/close

The whole tab array and webviews persist independent of the notch's view
cycle. Closing the notch (or auto-close, or app restart — see persistence)
never destroys a page. This is the single most important property for the
primary use case (leave a video playing, tuck the notch away, come back).

### Search-engine dispatch

The omnibox resolves input in three steps (pattern borrowed from the Search
app, MIT, used as reference only):

1. Has an `http`/`https` scheme and a host → navigate directly
2. Bare dotted domain (`example.com/page`) → prepend `https://`
3. Anything else → search via the configured engine (DuckDuckGo default,
   Google optional; set in Settings → Browser)

## Panel sizing

The notch's height while the Browser tab is active comes from one source of
truth — `WebTabsModel.customHeight` (exact, from a drag) or the
`browserPanelSize` preset (S 260 / M 360 / L 460 / XL 580):

- **Presets** — tap S/M/L/XL in the toolbar; picking one clears a custom
  height. XL is the default.
- **Handlebar** — the scrollbar-thumb-style capsule at the panel's bottom
  edge. Drag it and the panel's bottom edge follows the cursor 1:1 (down =
  taller). The height persists (in-memory; survives notch open/close, and the
  session file records nothing about size — the preset default wins after
  restart unless dragged again).

### How the resize actually works

Three sizing sites must agree (they all read the same two values):
`ContentView.dynamicNotchSize`, `DynamicIslandViewModel.calculateDynamicNotchSize()`,
and `AppDelegate.calculateRequiredNotchSize()`. The bevel drag calls
`DynamicIslandViewModel.applyBrowserHeight(_:)`, which force-resizes the
NSWindow and updates `notchSize` in one step.

Two hard-won details:

1. **The hosting view must track the window.** `FirstMouseHostingView` gets
   `autoresizingMask = [.width, .height]` — without it the window grew but
   the SwiftUI content kept the old size (black dead space, stranded bezel).

2. **The browser owns exactly one height.** `BrowserView` pins itself to
   `customHeight ?? preset` rather than filling with `maxHeight: .infinity`,
   which produced ambiguous layout inside the notch's VStack. While the
   browser tab is open, the generic notch-resize publishers (network HUD,
   timer, reminders, music state) are frozen — live web content perturbed
   SwiftUI intrinsic sizes and caused constant window jitter. Only tab
   switches, preset taps, and handlebar drags may move the window.

### The handlebar and gesture interception

The drag surface is a transparent `NSView` (`BezelStripNSView`) that
intercepts `leftMouseDown`/`leftMouseDragged`/`leftMouseUp` via **local
`NSEvent` monitors**, consuming them so nothing else reacts. Two reasons:

- Atoll installs a notch-level `DragGesture(minimumDistance: 0)` (for its
  tap/scroll-gesture machinery) that **swallows every mouse-down** before a
  plain `NSView.mouseDown` or SwiftUI gesture on the strip would fire. Local
  monitors run before SwiftUI's gesture machinery and can veto events.
- A SwiftUI `DragGesture` on the strip dies mid-drag: resizing the window
  under it re-lays-out its coordinate space and cancels the gesture. AppKit
  event streams are immune.

The drag math is **absolute, not accumulated**: the panel's bottom edge is
simply the cursor's distance from the screen top (the window is pinned to
the screen top, so bottom-edge Y = cursor Y from top). No anchors, no delta
accumulation — the window moving under the cursor can't cause drift.

The visible handlebar (scrollbar-thumb capsule, hover/drag brightening) is
painted in SwiftUI (`HandlebarIndicator`) — AppKit `draw()` proved visually
unreliable inside the notch's hosting stack — while the transparent NSView
handles only hit-testing.

## Pin & auto-close

- **Unpinned:** when the cursor leaves the notch, the panel closes after
  `browserAutoCloseDelay` (default 5s; Settings offers immediate/5/15/30/never).
- **Pinned:** never auto-closes; survives outside clicks and the toggle
  shortcut too. Unpinning while the cursor is away re-arms the timer via the
  `browserAutoCloseRearmRequested` notification (single owner of the close
  task: ContentView's `scheduleBrowserAutoClose`).
- The browser is exempt from Atoll's **scroll-to-close** gesture — scrolling
  a webpage must never read as a close swipe.
- Auto-close only fires when the cursor is genuinely off the notch, so
  watching a video inside the panel is never interrupted.

## Session persistence

- **Tab list + active selection** are saved to
  `~/Library/Application Support/DynamicIsland/browser-session.json` on every
  navigation and tab mutation. On relaunch, tabs restore (background tabs
  lazily, loading only when selected — same as NotchBrowser).
- **Logins** persist because webviews use WebKit's default disk-backed
  cookie store. One YouTube login survives notch cycles and app restarts.
  Home page is `https://www.youtube.com`.
- Known limitation: **passkeys/WebAuthn fail** inside the notch panel
  (`ASAuthorizationController` error 1004) — the system credential sheet
  won't present from a borderless non-activating window. Log in with a
  password or the cross-device QR flow; the session then persists.

## Dark mode

`browserForceDarkMode` (default on) pins each webview's `NSAppearance` to
`darkAqua`, so `prefers-color-scheme: dark` matches on every site regardless
of system appearance — the same mechanism Safari's automatic darkening uses.
The chrome itself is hard-black, matching the notch.

## Settings keys

| Key | Default | Purpose |
|---|---|---|
| `enableBrowserFeature` | `false` | Adds the Browser tab |
| `browserSearchEngine` | `.duckDuckGo` | Omnibox fallback search |
| `browserPanelSize` | `.extraLarge` | Preset notch height |
| `browserAutoCloseDelay` | `5` | Seconds before auto-close (0 = immediate, −1 = never) |
| `browserForceDarkMode` | `true` | Pin webviews to dark appearance |

## Integration points (all additive)

- `enums/generic.swift` — `.browser` case on `NotchViews`
- `DynamicIslandViewCoordinator.swift` — tab order; resize publisher
- `components/Tabs/TabSelectionView.swift` — the globe tab
- `ContentView.swift` — view routing, browser sizing branch, auto-close
  scheduling, scroll-close exemption
- `DynamicIslandApp.swift` — window sizing branch, jitter-freeze guards,
  hosting-view autoresizing, pin-aware toggle shortcut
- `models/DynamicIslandViewModel.swift` — `applyBrowserHeight`, sizing
- `models/Constants.swift` — the five Defaults keys
- `components/Settings/SettingsView.swift` — Browser settings tab

## Known limitations

- Passkeys/WebAuthn can't present from the notch window (see above).
- Page zoom is a plain `WKWebView.magnification` scale; fit-page is a fixed
  0.45× rather than per-page-computed.
- Fullscreen/DRM video inside the panel follows WebKit's normal rules; the
  panel doesn't bypass DRM.
- Debug `#if DEBUG` prints (`[Bezel]`, `[BrowserSize]`) remain from the
  build-out; they compile out of release builds.
