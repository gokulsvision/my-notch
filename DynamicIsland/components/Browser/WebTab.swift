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

        let config = configuration ?? WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.setValue(false, forKey: "drawsBackground") // keep notch surface visible during load
        webView = view
        applyAppearance(forceDark: forceDark, to: view)

        if !hasStartedLoading, let url = pendingURL {
            hasStartedLoading = true
            load(url: url)
        }
        return view
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
