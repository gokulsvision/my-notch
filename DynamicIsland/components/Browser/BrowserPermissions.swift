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

import Foundation

/// Per-site memory for the mini-browser's media permissions, so a site the user
/// has already allowed (or denied) isn't asked again. Backed by a small JSON
/// file next to ``WebTabsModel``'s session store.
///
/// Only an explicit "remember" choice is written; a one-off Allow/Deny is not
/// persisted, so the next request asks again. ``decision(for:kind:)`` returns
/// `nil` when the site has never been remembered.
final class BrowserPermissions {
    static let shared = BrowserPermissions()

    enum Kind: String, Codable {
        case audio
        case video
        case display
    }

    /// One site's remembered choices. A `nil` field means "not remembered".
    struct SitePermissions: Codable {
        var audio: Bool?
        var video: Bool?
        var display: Bool?

        subscript(kind: Kind) -> Bool? {
            get {
                switch kind {
                case .audio: return audio
                case .video: return video
                case .display: return display
                }
            }
            set {
                switch kind {
                case .audio: audio = newValue
                case .video: video = newValue
                case .display: display = newValue
                }
            }
        }
    }

    private let lock = NSLock()
    private var sites: [String: SitePermissions] = [:]

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("DynamicIsland", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("browser-permissions.json")
    }

    init() {
        load()
    }

    /// The remembered decision for `host`, or `nil` if never remembered.
    func decision(for host: String, kind: Kind) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return sites[host]?[kind]
    }

    /// Remembers an explicit Allow/Deny for `host`.
    func record(host: String, kind: Kind, allowed: Bool) {
        lock.lock()
        var entry = sites[host] ?? SitePermissions()
        entry[kind] = allowed
        sites[host] = entry
        lock.unlock()
        save()
    }

    /// Forgets every remembered site; the next request asks again.
    func resetAll() {
        lock.lock()
        sites.removeAll()
        lock.unlock()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let decoded = try? JSONDecoder().decode([String: SitePermissions].self, from: data) else {
            return
        }
        sites = decoded
    }

    private func save() {
        lock.lock()
        let snapshot = sites
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}
