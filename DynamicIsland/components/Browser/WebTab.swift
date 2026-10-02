/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import Defaults
import WebKit

/// One browser tab: a lazily created `WKWebView` that stays alive when hidden,
/// so switching tabs never reloads the page (same pattern as Search's web tabs).
final class WebTab: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()

    /// The persistent web view. Created on first navigation, kept for the
    /// tab's whole lifetime — hidden tabs keep rendering their page off-screen.
    /// ``WebTabsModel`` resets it to `nil` when recycling a full tab slot.
    var webView: WKWebView?

    /// URL used to create the web view, kept so a first navigation can be
    /// deferred until the view is actually needed.
    var pendingURL: URL?

    /// Back-reference to the owning tab list, used to route WebKit popups
    /// (OAuth logins, invites) into real notch-strip tabs. Weak so a tab never
    /// keeps the model alive.
    weak var tabsModel: WebTabsModel?

    /// True once a page has loaded (or a load was started) in `webView`.
    var hasStartedLoading = false

    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false

    /// Whether the user is currently editing the address field. While active,
    /// the field shows raw text instead of the live page URL.
    var isEditingAddress = false

    override init() {
        super.init()
    }

    init(initialURL: URL?) {
        super.init()
        pendingURL = initialURL
    }

    /// Creates the underlying `WKWebView` on first use and optionally loads
    /// `pendingURL`. Idempotent: later calls reuse the existing web view.
    /// When force-dark is on, the view's appearance is pinned to darkAqua so
    /// every page matches `prefers-color-scheme: dark` regardless of system
    /// appearance — the same mechanism Safari's automatic darkening uses.
    func ensureWebView(forceDark: Bool = true, configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        if let webView {
            return webView
        }

        let config = configuration ?? Self.makeRTCReadyConfiguration()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.setValue(false, forKey: "drawsBackground") // keep notch surface visible during load
        view.customUserAgent = Self.safariUserAgent()
        webView = view
        applyAppearance(forceDark: forceDark, to: view)

        if !hasStartedLoading, let url = pendingURL {
            hasStartedLoading = true
            load(url: url)
        }
        return view
    }

    /// Configuration tuned for real-time communication (voice, camera, screen
    /// share) so pages such as Discord behave as they do in Safari:
    /// - `mediaTypesRequiringUserActionForPlayback = []` lets WebRTC remote
    ///   audio and video autoplay instead of waiting on a user gesture.
    /// - `interruptAudioOnPageVisibilityChangeEnabled` is turned off so voice
    ///   keeps playing while the notch is hidden behind another app.
    /// - Inline media playback is not exposed on macOS (the property is
    ///   iOS-only) and already defaults on, so it needs no configuration here.
    /// - `fullScreenEnabled` is a valid KVC key; `hiddenPageAudioPlaybackEnabled`
    ///   is NOT KVC-compliant on this WebKit and crashes if set, so it is
    ///   deliberately omitted.
    static func makeRTCReadyConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.preferences.setValue(true, forKey: "fullScreenEnabled")
        config.preferences.setValue(false, forKey: "interruptAudioOnPageVisibilityChangeEnabled")
        return config
    }

    /// WKWebView's default macOS user agent ends at `…(KHTML, like Gecko)`
    /// with no `Version/<n> Safari/` tokens — sites that gate on "is this a
    /// real browser" (Discord's unsupported-browser screen, some OAuth
    /// providers) treat it as unknown and block it. Appending the installed
    /// Safari version makes the agent indistinguishable from Safari itself.
    static func safariUserAgent() -> String {
        let osPart = "Macintosh; Intel Mac OS X 10_15_7" // WebKit always reports this shim on modern macOS
        let base = "Mozilla/5.0 (\(osPart)) AppleWebKit/605.1.15 (KHTML, like Gecko)"
        let safariVersion = Bundle(url: URL(fileURLWithPath: "/Applications/Safari.app"))?
            .infoDictionary?["CFBundleShortVersionString"] as? String
            ?? ProcessInfo.processInfo.operatingSystemVersionString
        return "\(base) Version/\(safariVersion) Safari/605.1.15"
    }

    /// Applies or clears the dark-appearance pin on the live web view.
    /// Requires a reload when the effective appearance flips, so call this
    /// from a settings toggle, not per navigation.
    func applyForceDark(_ enabled: Bool) {
        guard let view = webView else {
            // Not created yet — the next ensureWebView applies it.
            return
        }
        applyAppearance(forceDark: enabled, to: view)
    }

    private func applyAppearance(forceDark: Bool, to view: WKWebView) {
        if forceDark {
            view.appearance = NSAppearance(named: .darkAqua)
        } else {
            view.appearance = nil
        }
    }

    func load(url: URL) {
        pendingURL = url
        hasStartedLoading = true
        let view = ensureWebView()
        view.load(URLRequest(url: url))
    }

    /// Search-engine dispatch, borrowed from Search (MIT): input without a
    /// scheme is routed to the search engine instead of failing as a URL.
    static func resolveAddress(_ input: String, searchEngine: BrowserSearchEngine) -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           url.host != nil {
            return url
        }
        // Bare domains without a scheme, e.g. "example.com" or "example.com/page".
        if trimmed.contains("."), !trimmed.contains(" "),
           let url = URL(string: "https://\(trimmed)"),
           url.host?.contains(".") == true {
            return url
        }
        return searchEngine.searchURL(for: trimmed)
    }

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func reload() {
        webView?.reload()
    }

    func stopLoading() {
        webView?.stopLoading()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        publishNavigationState(webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        publishNavigationState(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        publishNavigationState(webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        publishNavigationState(webView)
    }

    private func publishNavigationState(_ webView: WKWebView) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        objectWillChange.send()
    }

    // MARK: - WKUIDelegate: media capture

    /// Answers WebKit's camera/microphone request. A remembered per-site
    /// decision is applied silently; otherwise one alert is shown, with a
    /// "Remember" suppression box that persists the choice for that host.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let host = origin.host
        let kinds: [BrowserPermissions.Kind]
        switch type {
        case .camera: kinds = [.video]
        case .microphone: kinds = [.audio]
        case .cameraAndMicrophone: kinds = [.video, .audio]
        @unknown default: kinds = [.audio, .video]
        }

        let remembered = kinds.compactMap { BrowserPermissions.shared.decision(for: host, kind: $0) }
        if remembered.count == kinds.count {
            decisionHandler(remembered.allSatisfy { $0 } ? .grant : .deny)
            return
        }

        MainActor.assumeIsolated {
            let alert = self.makeMediaPermissionAlert(host: host, kinds: kinds)
            self.present(alert, on: webView.window) { response in
                let allowed = response == .alertFirstButtonReturn
                if alert.suppressionButton?.state == .on {
                    for kind in kinds {
                        BrowserPermissions.shared.record(host: host, kind: kind, allowed: allowed)
                    }
                }
                decisionHandler(allowed ? .grant : .deny)
            }
        }
    }

    /// Builds the one-time capture prompt, remembering the answer for `host`
    /// when the suppression box is ticked.
    @MainActor
    private func makeMediaPermissionAlert(host: String, kinds: [BrowserPermissions.Kind]) -> NSAlert {
        let needsVideo = kinds.contains(.video)
        let needsAudio = kinds.contains(.audio)
        let subject: String
        switch (needsVideo, needsAudio) {
        case (true, true): subject = "camera and microphone"
        case (true, false): subject = "camera"
        default: subject = "microphone"
        }

        let alert = NSAlert()
        alert.messageText = "Allow \(host) to use your \(subject)?"
        alert.informativeText = "The site will be able to see and hear you while this tab is open."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember for \(host)"
        return alert
    }

    /// Runs `alert` as a sheet on `window` when possible, falling back to a
    /// free-standing modal when the view is not yet in a window.
    @MainActor
    private func present(_ alert: NSAlert, on window: NSWindow?, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    /// Display share (screen/window picker). WebKit exposes this only through a
    /// private delegate method that exists on macOS 13+, so it is declared with
    /// an explicit Objective-C selector. It is intentionally not part of
    /// `WKUIDelegate`'s public surface, hence the `@objc` escape hatch.
    ///
    /// `WKDisplayCapturePermissionDecision` values are 0 deny, 1 screen prompt,
    /// 2 window prompt; returning 1 lets WebKit present its own picker, which on
    /// macOS mirrors Safari (whole-display selection). Verified to fire and to
    /// yield a working whole-screen capture on macOS.
    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func webView(
        _ webView: WKWebView,
        requestDisplayCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        withSystemAudio systemAudio: Bool,
        decisionHandler: @escaping (NSInteger) -> Void
    ) {
        decisionHandler(1)
    }

    // MARK: - WKUIDelegate: windows & dialogs

    /// Opens WebKit popups (OAuth logins such as "Continue with Google",
    /// invite and voice windows) as real notch-strip tabs instead of dropping
    /// them. Must return the new web view synchronously.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        return MainActor.assumeIsolated {
            guard let model = tabsModel else { return nil }
            // No initial URL: WebKit loads `navigationAction.request` into the
            // returned view itself, so pre-loading here would double-fetch.
            let newTab = model.openNewTab(activate: true)
            // WebKit requires the returned view to use the supplied
            // configuration; it is a copy of ours, so RTC settings carry over.
            return newTab.ensureWebView(
                forceDark: Defaults[.browserForceDarkMode],
                configuration: configuration
            )
        }
    }

    /// Closes the notch tab that owns a web view the page closed via
    /// `window.close()`.
    func webViewDidClose(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            guard let model = tabsModel,
                  let index = model.tabs.firstIndex(where: { $0.webView === webView }) else { return }
            model.closeTab(at: index)
        }
    }

    /// File uploads (avatar images, attachments) via the standard open panel.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        MainActor.assumeIsolated {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.canChooseFiles = true

            if let window = webView.window {
                panel.beginSheetModal(for: window) { response in
                    completionHandler(response == .OK ? panel.urls : nil)
                }
            } else {
                completionHandler(panel.runModal() == .OK ? panel.urls : nil)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        MainActor.assumeIsolated {
            let alert = NSAlert()
            alert.messageText = frame.request.url?.host ?? "This page says"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            present(alert, on: webView.window) { _ in completionHandler() }
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        MainActor.assumeIsolated {
            let alert = NSAlert()
            alert.messageText = frame.request.url?.host ?? "This page says"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            present(alert, on: webView.window) { completionHandler($0 == .alertFirstButtonReturn) }
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        MainActor.assumeIsolated {
            let alert = NSAlert()
            alert.messageText = frame.request.url?.host ?? "This page says"
            alert.informativeText = prompt
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")

            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
            field.stringValue = defaultText ?? ""
            alert.accessoryView = field

            present(alert, on: webView.window) { response in
                completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
            }
        }
    }
}

/// Height presets for the open notch while the Browser tab is active.
enum BrowserSizePreset: String, CaseIterable, Identifiable, Defaults.Serializable {
    case small
    case medium
    case large
    case extraLarge

    var id: String { rawValue }

    var height: CGFloat {
        switch self {
        case .small: return 260
        case .medium: return 360
        case .large: return 460
        case .extraLarge: return 580
        }
    }

    var localizedName: String {
        switch self {
        case .small: return String(localized: "Small")
        case .medium: return String(localized: "Medium")
        case .large: return String(localized: "Large")
        case .extraLarge: return String(localized: "Extra Large")
        }
    }
}

enum BrowserSearchEngine: String, CaseIterable, Identifiable, Defaults.Serializable {
    case duckDuckGo
    case google

    var id: String { rawValue }

    var name: String {
        switch self {
        case .duckDuckGo: return "DuckDuckGo"
        case .google: return "Google"
        }
    }

    func searchURL(for query: String) -> URL {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch self {
        case .duckDuckGo:
            return URL(string: "https://duckduckgo.com/?q=\(encoded)") ?? URL(string: "https://duckduckgo.com")!
        case .google:
            return URL(string: "https://www.google.com/search?q=\(encoded)") ?? URL(string: "https://www.google.com")!
        }
    }
}
