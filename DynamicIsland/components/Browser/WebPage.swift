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
import WebKit

/// SwiftUI wrapper around a persistent `WKWebView` instance.
///
/// SwiftUI has no native WebKit wrapper on macOS, so each browser tab owns one
/// long-lived `WKWebView` (see ``WebTab``) and this representable binds the
/// existing instance into the view tree without recreating it. Recreating the
/// view would reload the page and lose session state on every tab switch.
struct WebPage: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // The web view is owned and mutated by WebTab; nothing to sync here.
    }
}
