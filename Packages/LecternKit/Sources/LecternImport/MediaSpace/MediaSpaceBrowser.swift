import LecternCore
import Observation
import SwiftUI
import WebKit

/// Observable state of a `MediaSpaceBrowserView`, for the app's surrounding sheet chrome.
@MainActor @Observable
public final class MediaSpaceBrowserState {
    /// The address MediaSpace opens at.
    public static let homeURL = URL(string: "https://mediaspace.illinois.edu")!

    /// True while the page shown is a lecture (as opposed to sign-in or browsing).
    public private(set) var isOnMediaPage = false
    /// The lecture found on the current page; `nil` until the signed session has been seen
    /// (usually as soon as the page loads, otherwise after the user presses play).
    public private(set) var found: MediaSpaceSource?
    public private(set) var pageTitle: String?
    public private(set) var currentURL: URL?
    public private(set) var isLoading = false
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false

    private weak var webView: WKWebView?
    private var detector = MediaSpaceDetector()

    public init() {}

    public func goBack() { webView?.goBack() }
    public func goForward() { webView?.goForward() }
    public func reload() { webView?.reload() }
    public func goHome() { webView?.load(URLRequest(url: Self.homeURL)) }

    // MARK: Driven by the coordinator

    fileprivate func attach(_ webView: WKWebView) {
        self.webView = webView
        webView.load(URLRequest(url: Self.homeURL))
    }

    /// Syncs navigation state from the web view. Returns the lecture again when learning the page
    /// title completed its details.
    fileprivate func refresh(from webView: WKWebView) -> MediaSpaceSource? {
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        pageTitle = webView.title.flatMap(MediaSpaceScraper.cleanTitle)
        let page = webView.url.map(Self.withoutFragment)
        if page != currentURL {
            currentURL = page
            detector.pageChanged(to: page)
            isOnMediaPage = MediaSpaceDetector.isMediaPage(page)
            found = nil
        }
        guard let updated = detector.titleChanged(webView.title) else { return nil }
        found = updated
        return updated
    }

    /// In-page anchors don't change which lecture is shown.
    private static func withoutFragment(_ url: URL) -> URL {
        guard url.fragment != nil, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.fragment = nil
        return components.url ?? url
    }

    fileprivate func receive(_ signal: MediaSpaceDetector.Signal) -> MediaSpaceSource? {
        guard let source = detector.ingest(signal) else { return nil }
        found = source
        return source
    }
}

/// A web view onto Illinois MediaSpace that keeps the user's SSO login (persistent website data
/// store) and reports the lecture's Kaltura session via `onFound` as soon as it appears
/// (`onFound` may be called a second time for the same lecture once its title becomes known). Draws no
/// chrome of its own; the host wraps it in a sheet using `MediaSpaceBrowserState`.
///
/// Credentials are entered directly into the web page and never seen by Lectern; the scraped
/// session token is handed to `onFound` only and neither stored nor logged here.
public struct MediaSpaceBrowserView: NSViewRepresentable {
    private let state: MediaSpaceBrowserState
    private let onFound: (MediaSpaceSource) -> Void

    /// - Parameter state: pass your own to drive navigation buttons; a private one is used otherwise.
    public init(state: MediaSpaceBrowserState? = nil, onFound: @escaping (MediaSpaceSource) -> Void) {
        self.state = state ?? MediaSpaceBrowserState()
        self.onFound = onFound
    }

    public func makeCoordinator() -> Coordinator { Coordinator(state: state, onFound: onFound) }

    public func makeNSView(context: Context) -> WKWebView {
        let webView = Self.makeWebView(coordinator: context.coordinator)
        state.attach(webView)
        return webView
    }

    /// Web view with the persistent data store, the detection script and the delegates wired up
    /// (not yet navigated anywhere).
    static func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: MediaSpaceBrowserScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.add(WeakMessageHandler(coordinator), name: MediaSpaceBrowserScript.handlerName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        coordinator.observe(webView)
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onFound = onFound
    }

    public static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: MediaSpaceBrowserScript.handlerName)
        coordinator.stopObserving()
    }

    @MainActor
    public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        private let state: MediaSpaceBrowserState
        fileprivate var onFound: (MediaSpaceSource) -> Void
        private var observations: [NSKeyValueObservation] = []

        init(state: MediaSpaceBrowserState, onFound: @escaping (MediaSpaceSource) -> Void) {
            self.state = state
            self.onFound = onFound
        }

        fileprivate func observe(_ webView: WKWebView) {
            observations = [
                webView.observe(\.url) { [weak self] view, _ in MainActor.assumeIsolated { self?.refresh(view) } },
                webView.observe(\.title) { [weak self] view, _ in MainActor.assumeIsolated { self?.refresh(view) } },
                webView.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.refresh(view) } },
                webView.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.refresh(view) } },
                webView.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.refresh(view) } },
            ]
        }

        private func refresh(_ webView: WKWebView) {
            if let updated = state.refresh(from: webView) { onFound(updated) }
        }

        fileprivate func stopObserving() { observations.removeAll() }

        // MARK: Script messages

        public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let origin = message.frameInfo.securityOrigin
            guard Self.isTrusted(scheme: origin.protocol, host: origin.host),
                  let body = message.body as? [String: Any] else { return }
            // KVO may lag the message; make sure the title and address are current before resolving.
            if let webView = message.webView { refresh(webView) }
            let signal = MediaSpaceDetector.Signal(
                partnerID: (body["partnerId"] as? String) ?? (body["partnerId"] as? NSNumber)?.stringValue,
                entryID: body["entryId"] as? String,
                ks: body["ks"] as? String
            )
            if let source = state.receive(signal) { onFound(source) }
        }

        /// Only https pages of MediaSpace itself or Kaltura may feed us identifiers (sign-in pages never need to; navigation is unrestricted).
        /// The origin is that of the frame that posted the message, so an untrusted iframe inside a
        /// trusted page (or the reverse) is judged by its own address.
        static func isTrusted(scheme: String, host: String) -> Bool {
            scheme.lowercased() == "https" && MediaSpaceDetector.isTrustedHost(host, domains: ["mediaspace.illinois.edu", "kaltura.com"])
        }

        // MARK: Navigation

        public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            refresh(webView)
        }

        /// Sign-in and player pop-ups open in the same view, so the session stays in one place.
        public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}

/// `WKUserContentController` retains its handlers; this breaks the cycle back to the coordinator.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
