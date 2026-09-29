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

import SwiftUI
import Defaults
import WebKit

/// Long-lived holder for ``WebTabsModel``. The model must outlive individual
/// view lifecycles so open pages survive notch close/reopen and tab switches;
/// keeping it on a shared singleton gives ``BrowserView`` one stable owner.
@MainActor
final class WebTabsModelHolder {
    static let shared = WebTabsModelHolder()
    let model = WebTabsModel()
}

/// Compact chrome for the notch-sized mini-browser: a small tab strip, back /
/// forward / reload controls, an address field that falls back to search, a
/// thin progress bar, and one-tap zoom + notch-size controls. The chrome can
/// be hidden entirely so the page fills the panel.
struct BrowserView: View {
    @ObservedObject private var coordinator = DynamicIslandViewCoordinator.shared
    @StateObject private var webTabs = WebTabsModelHolder.shared.model
    @EnvironmentObject var vm: DynamicIslandViewModel
    @FocusState private var addressFocused: Bool
    @Default(.browserPanelSize) private var browserPanelSize

    var body: some View {
        VStack(spacing: 0) {
            if webTabs.tabs.isEmpty {
                emptyState
            } else {
                toolbar
                Divider()
                    .padding(.horizontal, 12)
                    .overlay(Color.white.opacity(0.12).frame(height: 1))
                pageContent
                bezel
            }
        }
        // EXACT height instead of infinite fill: the browser owns precisely
        // the height the notch is sized for (bezel-dragged or preset), so
        // toolbar / page / bezel always lay out within the visible window —
        // no dead black bands below the content and no clipped bezel.
        .frame(maxWidth: .infinity)
        .frame(height: webTabs.customHeight ?? browserPanelSize.height)
        .background(Color(nsColor: .black).opacity(0.98))
        .clipShape(browserClipShape())
        .onAppear {
            #if DEBUG
            print("[BrowserSize] BrowserView onAppear height=\(Int(webTabs.customHeight ?? browserPanelSize.height))")
            #endif
            webTabs.restoreSessionIfNeeded()
            webTabs.refreshNavigationState()
        }
        .overlay(alignment: .bottomTrailing) {
            if chromeHidden {
                Button {
                    withAnimation(.smooth(duration: 0.15)) { chromeHidden = false }
                } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(5)
                        .background(Circle().fill(Color.black.opacity(0.65)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .padding(.bottom, 6)
            }
        }
    }

    /// Bottom bezel: a grab strip for stretching the panel. Because the
    /// notch window is anchored to the TOP of the screen, its bottom edge
    /// moves down as the panel grows — so drag DOWN to make it taller, UP
    /// to shrink. Clicking the arrows resizes in 40pt steps (reliable);
    /// dragging the strip also works via a native NSView tracker.
    private var bezel: some View {
        // SwiftUI paints the handlebar (guaranteed visible); the transparent
        // NSView underneath is hit-test-only and owns the drag.
        ZStack {
            HandlebarIndicator(
                currentHeight: webTabs.customHeight ?? browserPanelSize.height
            )
            BezelDragStrip(
                currentHeight: webTabs.customHeight ?? browserPanelSize.height,
                onStretch: { newHeight in
                    webTabs.customHeight = newHeight
                    vm.applyBrowserHeight(newHeight)
                }
            )
        }
        .frame(height: 26)
        .help("Drag the bar to make the browser taller or shorter")
    }

    // MARK: - Toolbar

    /// Chrome is conditionally hidden so the page can own the whole panel.
    @State private var chromeHidden = false

    private var toolbar: some View {
        Group {
            if chromeHidden {
                HStack {
                    Spacer()
                }
                .frame(height: 4)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.smooth(duration: 0.15)) { chromeHidden = false }
                }
            } else {
                VStack(spacing: 0) {
                    tabStrip
                    HStack(spacing: 6) {
                        navButton("chevron.left", enabled: activeTab?.canGoBack == true) {
                            activeTab?.goBack()
                        }
                        navButton("chevron.right", enabled: activeTab?.canGoForward == true) {
                            activeTab?.goForward()
                        }
                        navButton(activeTab?.isLoading == true ? "xmark" : "arrow.clockwise",
                                  enabled: true) {
                            if activeTab?.isLoading == true {
                                activeTab?.stopLoading()
                            } else {
                                activeTab?.reload()
                            }
                        }

                        addressField

                        zoomControls

                        navButton("plus", enabled: webTabs.tabs.count < WebTabsModel.maxTabs) {
                            webTabs.openNewTab()
                            addressFocused = true
                        }
                        sizeControls
                        cinemaModeButton
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)

                    if activeTab?.isLoading == true {
                        ProgressView(value: loadingProgress)
                            .progressViewStyle(.linear)
                            .tint(.white.opacity(0.7))
                            .frame(height: 2)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 2)
                    }
                }
            }
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 6) {
            ForEach(Array(webTabs.tabs.enumerated()), id: \.element.id) { index, tab in
                BrowserTabStripButton(
                    title: title(for: tab),
                    isSelected: index == webTabs.activeTabIndex,
                    isLoading: tab.isLoading
                ) {
                    webTabs.selectTab(at: index)
                } onClose: {
                    webTabs.closeTab(at: index)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var addressField: some View {
        TextField("Search or enter website", text: $webTabs.addressText)
            .textFieldStyle(.plain)
            .focused($addressFocused)
            .submitLabel(.go)
            .onSubmit {
                addressFocused = false
                activeTab?.isEditingAddress = false
                webTabs.commitAddress()
            }
            .onChange(of: addressFocused) { _, focused in
                activeTab?.isEditingAddress = focused
                if focused {
                    // Select the whole URL so typing replaces it, like a real
                    // browser's omnibox.
                    webTabs.addressText = webTabs.activeURL?.absoluteString ?? ""
                } else {
                    webTabs.syncAddressFromTab()
                }
            }
            .foregroundStyle(.white)
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.12))
            )
            .frame(maxWidth: .infinity)
    }

    // MARK: - Zoom, size & cinema controls

    /// Explicit zoom out / in pair plus the fit toggle — one button each,
    /// always visible, no symbol-ambiguity.
    private var zoomControls: some View {
        HStack(spacing: 2) {
            navButton("minus.magnifyingglass", enabled: true) { webTabs.zoomOut() }
            navButton("plus.magnifyingglass", enabled: true) { webTabs.zoomIn() }
            fitButton
        }
    }

    /// Fit toggles between the zoomed-out whole-page overview and 100%.
    private var fitButton: some View {
        Button {
            let current = activeTab?.webView?.magnification ?? 1.0
            if current < 0.7 {
                webTabs.actualSize()
            } else {
                webTabs.fitToPage()
            }
        } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isFitActive ? .white : .white.opacity(0.45))
                .frame(width: 22, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isFitActive ? Color.accentColor.opacity(0.55) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Fit whole page in panel (toggle)")
    }

    private var isFitActive: Bool {
        (activeTab?.webView?.magnification ?? 1.0) < 0.7
    }

    /// Selecting a preset clears any bezel-dragged height so the preset
    /// takes effect again.
    private var sizeControls: some View {
        HStack(spacing: 2) {
            ForEach(BrowserSizePreset.allCases) { preset in
                Button {
                    browserPanelSize = preset
                    webTabs.customHeight = nil
                    vm.applyBrowserHeight(preset.height)
                } label: {
                    Text(shortLabel(for: preset))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(browserPanelSize == preset ? .white : .white.opacity(0.45))
                        .frame(width: preset == .extraLarge ? 26 : 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(browserPanelSize == preset ? Color.accentColor.opacity(0.55) : Color.white.opacity(0.08))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Notch size: \(preset.localizedName)")
            }
        }
    }

    private func shortLabel(for preset: BrowserSizePreset) -> String {
        switch preset {
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        case .extraLarge: return "XL"
        }
    }

    /// Cinema Mode: keeps the notch open until toggled off — outside clicks
    /// don't dismiss it. Highlighted while on.
    private var cinemaModeButton: some View {
        Button {
            webTabs.isCinemaMode.toggle()
        } label: {
            Image(systemName: webTabs.isCinemaMode ? "film.fill" : "film")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(webTabs.isCinemaMode ? .white : .white.opacity(0.45))
                .frame(width: 22, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(webTabs.isCinemaMode ? Color.accentColor.opacity(0.55) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Cinema mode — keep open until toggled off")
    }

    // MARK: - Content

    @ViewBuilder
    private var pageContent: some View {
        ZStack {
            if let tab = activeTab {
                WebPage(webView: tab.ensureWebView(forceDark: Defaults[.browserForceDarkMode]))
                    .id(tab.id)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    // Interaction inside the page keeps the notch open.
                    coordinator.suppressHoverOpen(for: 0.6)
                }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.55))
            Text("No tabs open")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Button {
                webTabs.openNewTab()
                addressFocused = true
            } label: {
                Text("Open a new tab")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.12)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var activeTab: WebTab? {
        webTabs.activeTab
    }

    private var loadingProgress: Double {
        // WKWebView's progress KVO isn't wired here; show a steady mid-bar
        // while a load is in flight, driven purely by the loading flag.
        activeTab?.isLoading == true ? 0.5 : 0
    }

    private func title(for tab: WebTab) -> String {
        let url = tab.webView?.url ?? tab.pendingURL
        if let host = url?.host, !host.isEmpty {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        return "New Tab"
    }

    private func navButton(_ systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(enabled ? Color.white.opacity(0.9) : Color.white.opacity(0.3))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func browserClipShape() -> some Shape {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }
}

/// One pill in the browser's own mini tab strip.
private struct BrowserTabStripButton: View {
    let title: String
    let isSelected: Bool
    let isLoading: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: isSelected ? "globe" : "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.white.opacity(isSelected ? 0.8 : 0.25))
            }
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.55))
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(isSelected ? Color.white.opacity(0.18) : Color.white.opacity(0.06))
        )
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .frame(maxWidth: 110)
    }
}

/// SwiftUI-painted handlebar: a macOS scrollbar-thumb replica. Drawing it in
/// SwiftUI (rather than the NSView) guarantees it renders — the AppKit strip
/// proved visually unreliable inside the notch's hosting stack.
private struct HandlebarIndicator: View {
    let currentHeight: CGFloat
    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let hovered = isHovering || isDragging
            let thumbHeight: CGFloat = hovered ? 7 : 6
            let thumbWidth: CGFloat = hovered ? min(180, 180) : min(150, 150)
            Capsule()
                .fill(Color.white.opacity(isDragging ? 0.95 : (isHovering ? 0.75 : 0.5)))
                .frame(width: thumbWidth, height: thumbHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.12), value: hovered)
                .onHover { hovering in
                    isHovering = hovering
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in isDragging = true }
                        .onEnded { _ in isDragging = false }
                )
        }
    }
}

/// Transparent, hit-test-only drag surface: intercepts mouse events before
/// the notch-level DragGesture (which otherwise swallows them); the panel's
/// bottom edge tracks the cursor 1:1 while held.
private struct BezelDragStrip: NSViewRepresentable {
    let currentHeight: CGFloat
    let onStretch: (CGFloat) -> Void

    func makeNSView(context: Context) -> BezelStripNSView {
        let view = BezelStripNSView()
        view.onStretch = onStretch
        return view
    }

    func updateNSView(_ nsView: BezelStripNSView, context: Context) {
        nsView.onStretch = onStretch
        nsView.currentHeight = currentHeight
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {}
}

private final class BezelStripNSView: NSView {
    var onStretch: ((CGFloat) -> Void)?
    var currentHeight: CGFloat = 0
    private(set) var isDragging = false
    #if DEBUG
    private var didLogDraw = false
    #endif
    /// Local event monitors see every event in this app BEFORE SwiftUI's
    /// gesture recognizers get a say. Without this, the notch-level
    /// DragGesture(minimumDistance: 0) swallows mouse-downs and the strip
    /// never sees a single event.
    private var downMonitor: Any?
    private var dragMonitor: Any?
    private var upMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitors()
        // Repaint on hover enter/exit so the indicator brightens under the
        // cursor and dims when it leaves.
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(tracking)
    }

    override func mouseEntered(with event: NSEvent) {
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        needsDisplay = true
    }

    private func installMonitors() {
        tearDownMonitors()
        guard window != nil else { return }

        downMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.insetBy(dx: 0, dy: -2).contains(point) else { return event }
            self.isDragging = true
            return nil // consumed: don't let the notch's tap/pan gestures react
        }

        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            guard let self, self.isDragging, event.window === self.window else { return event }
            self.trackDrag()
            return nil // consume so the notch's pan gesture never sees it
        }

        upMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            if self.isDragging {
                self.isDragging = false
                return nil
            }
            return event
        }
    }

    private func tearDownMonitors() {
        [downMonitor, dragMonitor, upMonitor].compactMap { $0 }.forEach { NSEvent.removeMonitor($0) }
        downMonitor = nil
        dragMonitor = nil
        upMonitor = nil
    }

    deinit {
        // NSEvent monitors must be removed on the main thread.
        if let downMonitor { NSEvent.removeMonitor(downMonitor) }
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        if let upMonitor { NSEvent.removeMonitor(upMonitor) }
    }

    private func trackDrag() {
        // Pure edge-tracking, no anchors: the panel's bottom edge sits at the
        // cursor. The window is pinned to the screen top, so its bottom edge
        // is simply the cursor's distance from the screen top — absolute,
        // re-derived every event, immune to the window moving underneath.
        let mouse = NSEvent.mouseLocation
        let screenFrame = window?.screen?.frame ?? NSScreen.main?.frame ?? .zero
        let mouseYFromTop = screenFrame.maxY - mouse.y
        let newHeight = min(max(mouseYFromTop, 220), screenFrame.height - 140)
        onStretch?(newHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        // The handlebar is painted by HandlebarIndicator in SwiftUI; this
        // view is transparent and hit-test-only.
        #if DEBUG
        if !didLogDraw {
            didLogDraw = true
            print("[Bezel] draw bounds=\(bounds)")
        }
        #endif
    }

    private var isCursorInside: Bool {
        guard let window else { return false }
        let mouse = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return bounds.insetBy(dx: -2, dy: -2).contains(convert(mouse, from: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }
}
