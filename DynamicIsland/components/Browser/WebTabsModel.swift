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

import Combine
import Defaults
import SwiftUI
import WebKit

/// View model behind ``BrowserView``: owns the tab list (max 4), the active
/// tab, and address-bar state. Tabs are kept alive when hidden so switching
/// never reloads them, and the model outlives notch open/close cycles because
/// it lives on the shared coordinator.
@MainActor
final class WebTabsModel: ObservableObject {
    static let maxTabs = 4

    @Published var tabs: [WebTab] = []
    @Published var activeTabIndex: Int = 0 {
        didSet {
            syncActiveTabPublishers()
        }
    }
    /// When on (Cinema Mode), outside clicks never dismiss the browser;
    /// the panel stays up until the toggle is switched off.
    @Published var isCinemaMode = false
    /// Exact panel height set by dragging the bottom bezel. When set, it
    /// overrides the S/M/L/XL preset until the user picks a preset again.
    @Published var customHeight: CGFloat?
    @Published var addressText: String = ""
    @Published var searchEngine: BrowserSearchEngine = .duckDuckGo

    /// Bumped whenever the active tab's URL changes so the address field can
    /// follow page navigations without rebinding per tab.
    @Published var activeURL: URL?

    private var cancellables = Set<AnyCancellable>()

    var activeTab: WebTab? {
        guard tabs.indices.contains(activeTabIndex) else { return nil }
        return tabs[activeTabIndex]
    }

    // MARK: - Tab lifecycle

    @discardableResult
    func openNewTab(url: URL? = nil, activate: Bool = true) -> WebTab {
        if tabs.count >= Self.maxTabs {
            // Recycle the least recently used non-active tab when full.
            let candidate = tabs.indices
                .filter { $0 != activeTabIndex }
                .min { tabs[$0].id < tabs[$1].id } ?? 0
            let recycled = tabs[candidate]
            recycled.webView = nil
            recycled.pendingURL = url
            recycled.hasStartedLoading = url == nil
            recycled.tabsModel = self
            if activate { activeTabIndex = candidate }
            if activate, let url {
                recycled.load(url: url)
                addressText = Self.displayURL(url)
            }
            objectWillChange.send()
            return recycled
        }

        let tab = WebTab(initialURL: url)
        tab.tabsModel = self
        tabs.append(tab)
        if activate {
            activeTabIndex = tabs.count - 1
            addressText = url.map(Self.displayURL) ?? ""
            activeURL = url
        }
        observeTab(tab)
        return tab
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let closingActive = index == activeTabIndex
        let closingLast = tabs.count == 1

        tabs.remove(at: index)

        if closingLast {
            activeTabIndex = 0
            addressText = ""
            activeURL = nil
            saveSession()
            return
        }

        if index < activeTabIndex {
            activeTabIndex -= 1
        } else if closingActive {
            activeTabIndex = min(index, tabs.count - 1)
        }
        addressText = activeTab?.webView?.url.map(Self.displayURL) ?? ""
        saveSession()
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index), index != activeTabIndex else { return }
        activeTabIndex = index
        let tab = tabs[index]
        _ = tab.ensureWebView(forceDark: forceDarkMode)
        addressText = tab.webView?.url.map(Self.displayURL) ?? tab.pendingURL.map(Self.displayURL) ?? ""
        activeURL = tab.webView?.url ?? tab.pendingURL
    }

    // MARK: - Force dark mode

    /// Applies or clears the dark pin on every live web view. Toggled from
    /// Settings; a reload makes pages re-evaluate their color scheme.
    func setForceDarkMode(_ enabled: Bool) {
        Defaults[.browserForceDarkMode] = enabled
        for tab in tabs {
            tab.applyForceDark(enabled)
            tab.reload()
        }
    }

    private var forceDarkMode: Bool {
        Defaults[.browserForceDarkMode]
    }

    // MARK: - Session persistence

    /// Home page: YouTube. Logged-in state persists via WebKit's default
    /// (disk-backed) cookie store, so one login survives app restarts.
    static let homePage = URL(string: "https://www.youtube.com")!

    private struct BrowserSessionSnapshot: Codable {
        var urls: [String]
        var activeIndex: Int
    }

    private static var sessionFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("DynamicIsland", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("browser-session.json")
    }

    private var didRestore = false

    /// Restores the saved tab session on first access, or seeds a single
    /// YouTube home tab on very first launch. Background tabs restore lazily:
    /// they load only when selected, matching the keep-tab-alive pattern.
    func restoreSessionIfNeeded() {
        guard !didRestore else { return }
        didRestore = true
        guard tabs.isEmpty else { return }

        if let data = try? Data(contentsOf: Self.sessionFileURL),
           let snapshot = try? JSONDecoder().decode(BrowserSessionSnapshot.self, from: data) {
            var restoredActive = snapshot.activeIndex
            for (index, raw) in snapshot.urls.enumerated() {
                guard let url = URL(string: raw), raw.hasPrefix("http") else {
                    if index <= snapshot.activeIndex {
                        restoredActive = max(restoredActive - 1, 0)
                    }
                    continue
                }
                tabs.append(WebTab(initialURL: url))
            }
            for tab in tabs {
                tab.tabsModel = self
                observeTab(tab)
            }
            if tabs.isEmpty {
                openNewTab(url: Self.homePage, activate: true)
            } else {
                activeTabIndex = min(max(restoredActive, 0), tabs.count - 1)
                syncAddressFromTab()
            }
        } else {
            openNewTab(url: Self.homePage, activate: true)
        }
    }

    /// Writes the current tab list + selection to disk. Called on every tab
    /// lifecycle mutation and on page navigations (via the tab observer).
    func saveSession() {
        let snapshot = BrowserSessionSnapshot(
            urls: tabs.map { ($0.webView?.url ?? $0.pendingURL)?.absoluteString ?? "" },
            activeIndex: activeTabIndex
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: Self.sessionFileURL, options: .atomic)
        }
    }

    // MARK: - Navigation

    /// Resolves the address field and navigates: URL if scheme present,
    /// bare domain if dotted, otherwise a web search.
    func commitAddress() {
        let input = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            syncAddressFromTab()
            return
        }
        let url = WebTab.resolveAddress(input, searchEngine: searchEngine)
        let tab = activeTab ?? openNewTab(activate: true)
        tab.load(url: url)
        activeURL = url
        addressText = Self.displayURL(url)
        saveSession()
        objectWillChange.send()
    }

    func searchEngineChanged(_ engine: BrowserSearchEngine) {
        searchEngine = engine
    }

    // MARK: - Zoom

    /// Applies a page zoom step to the active tab. Zoom is per-tab, so a
    /// video enlarged on one tab doesn't affect a doc open in another.
    func zoomIn() {
        applyZoom(delta: +0.1)
    }

    func zoomOut() {
        applyZoom(delta: -0.1)
    }

    /// "Fit page" mode: scales the whole page down so the full webpage is
    /// visible inside the small notch panel — the zoomed-out overview.
    func fitToPage() {
        setPageMagnification(WebTabsModel.fitMagnification)
    }

    func actualSize() {
        setPageMagnification(1.0)
    }

    private func applyZoom(delta: Double) {
        guard let view = activeTab?.webView else { return }
        let current = view.magnification
        let target = min(3.0, max(0.2, current + delta))
        setPageMagnification(target)
    }

    /// WKWebView's magnification API lives behind a KVC selector in older
    /// SDKs; setting `magnification` directly is the supported path here.
    private func setPageMagnification(_ value: CGFloat) {
        activeTab?.webView?.magnification = value
    }

    static let fitMagnification: CGFloat = 0.45

    /// Refreshes navigation affordances (back/forward) from the active web view.
    func refreshNavigationState() {
        syncActiveTabPublishers()
    }

    // MARK: - Address bar

    static func displayURL(_ url: URL) -> String {
        url.absoluteString
    }

    func syncAddressFromTab() {
        guard let tab = activeTab else {
            addressText = ""
            activeURL = nil
            return
        }
        let url = tab.webView?.url ?? tab.pendingURL
        addressText = url.map(Self.displayURL) ?? ""
        activeURL = url
    }

    // MARK: - Private

    private func observeTab(_ tab: WebTab) {
        tab.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak tab] _ in
                guard let self, let tab else { return }
                guard self.activeTab === tab else { return }
                // Persist the session whenever the active tab navigates so a
                // login or page move survives app restarts.
                if self.activeURL != (tab.webView?.url ?? tab.pendingURL) {
                    self.saveSession()
                }
                self.syncActiveTabPublishers()
            }
            .store(in: &cancellables)
    }

    private func syncActiveTabPublishers() {
        guard let tab = activeTab else {
            activeURL = nil
            return
        }
        let url = tab.webView?.url ?? tab.pendingURL
        if activeURL != url {
            activeURL = url
        }
        if !tab.isEditingAddress {
            let display = url.map(Self.displayURL) ?? ""
            if addressText != display {
                addressText = display
            }
        }
    }
}
