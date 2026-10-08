import Foundation
import LecternCore
import SwiftUI

/// Everything one window remembers about where it is: sidebar selection, which screen the detail column
/// shows, the Library search, and the Course Ask inspector. Each window (scene) owns one, so New Window
/// gives a window of its own instead of a second view onto the first's state (B32). The library, the open
/// lectures, settings and services stay shared in `AppModel`.
@Observable
@MainActor
final class WindowNavigation {
    var sidebarSelection: SidebarItem? = .all
    var columnVisibility: NavigationSplitViewVisibility
    var path: [Route] = []
    var searchText = ""
    var searchScope: LibrarySearchScope = .all
    private(set) var searchResults: [LibrarySearchHit] = []
    private(set) var isSearching = false
    /// Where the lecture being opened should land (search hits, course citations); the session
    /// view takes it with `takePendingNavigation(for:)`.
    private(set) var pendingNavigation: PendingNavigation?
    var showCourseAsk = false
    /// This window is the key window: keyboard commands and notifications act here only.
    var isKey = false
    /// The sidebar state to return to when the recording this window hosts ends.
    var restoredVisibility: NavigationSplitViewVisibility = .all

    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(columnVisibility: NavigationSplitViewVisibility = .all) {
        self.columnVisibility = columnVisibility
    }

    /// The lecture on screen in this window, if the detail column shows one.
    var visibleSessionID: UUID? {
        if case .session(let id) = path.last { id } else { nil }
    }

    func requestLanding(_ navigation: PendingNavigation) { pendingNavigation = navigation }

    /// Hands the pending navigation to the session view showing `id` (once).
    func takePendingNavigation(for id: UUID) -> PendingNavigation? {
        guard let nav = pendingNavigation, nav.sessionID == id else { return nil }
        pendingNavigation = nil
        return nav
    }

    /// Re-runs the Library search for the current text and scope, after a pause in typing. A newer call
    /// cancels the older search, whose results are then discarded.
    func searchTextChanged(search: @escaping @Sendable (String, LibrarySearchScope, [LectureSession]) async throws -> [LibrarySearchHit], library: [LectureSession]) {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        let scope = searchScope
        searchTask = Task {
            do {
                // Wait for a pause in typing: a search scans every transcript.
                try await Task.sleep(for: .milliseconds(200))
                let hits = try await search(query, scope, library)
                guard !Task.isCancelled else { return }
                searchResults = hits
            } catch {
                guard !Task.isCancelled else { return }
                searchResults = []
            }
            isSearching = false
        }
    }
}

// MARK: - Commands for the key window only

private struct KeyWindowCommand: ViewModifier {
    var name: Notification.Name
    var perform: () -> Void
    @Environment(\.controlActiveState) private var controlActiveState

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: name)) { _ in
            // Every open window's views hear the notification; only the key window acts on it.
            if controlActiveState == .key { perform() }
        }
    }
}

extension View {
    /// Runs `perform` when the menu command `name` is posted and this view's window is the key window.
    func onWindowCommand(_ name: Notification.Name, perform: @escaping () -> Void) -> some View {
        modifier(KeyWindowCommand(name: name, perform: perform))
    }
}
