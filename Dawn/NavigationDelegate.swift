import AppKit
import WebKit

// MARK: - Navigation Delegate (handles navigation policies, new tabs, downloads)
class NavigationDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// Callback when a new tab is requested. Bool indicates whether to switch focus.
    var onNewTabRequested: ((URL, Bool) -> Void)?
    var onNewWindowRequested: ((URL) -> Void)?
    var onDropOpen: (([URL]) -> Void)?
    // a page shown in a terminal has nowhere to show a native menu, which would otherwise open on its own
    var showsContextMenus = true

    // main-frame navigation lifecycle: a provisional navigation's url is tentative until it commits,
    // and is abandoned when it fails (which is also how a navigation that became a download ends)
    var onProvisionalStart: (() -> Void)?
    var onProvisionalEnd: (() -> Void)?
    // a new page replaced the old one, and later finished loading (or stopped short of it)
    // the request a main-frame navigation is about to make, before it's known whether it commits
    var onMainFrameRequest: ((URLRequest) -> Void)?
    var onCommit: ((WKNavigation?) -> Void)?
    var onFinish: ((WKNavigation?) -> Void)?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        onProvisionalStart?()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        onProvisionalEnd?()
        onCommit?(navigation)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish?(navigation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onFinish?(navigation)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onProvisionalEnd?()
    }

    // MARK: - WKNavigationDelegate

    // the preferences variant lets each navigation pick up the develop menu's javascript setting; a web
    // view's configuration is a copy once created, so this is the supported place to change it
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.allowsContentJavaScript = !DevelopSettings.javaScriptDisabled
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow, preferences)
            return
        }

        if navigationAction.targetFrame?.isMainFrame == true, let dawn = webView as? DawnWebView,
           let dropped = dawn.claimDrop(loading: url) {
            decisionHandler(.cancel, preferences)
            onDropOpen?(dropped)
            return
        }

        // target="_blank" or window.open(): targetFrame is nil
        if navigationAction.targetFrame == nil {
            onNewTabRequested?(url, true)
            decisionHandler(.cancel, preferences)
            return
        }

        // links with a download attribute (including blob: and data: ones)
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }

        // Cmd+click on a link opens in new tab (background)
        if navigationAction.navigationType == .linkActivated && navigationAction.modifierFlags.contains(.command) {
            onNewTabRequested?(url, false)
            decisionHandler(.cancel, preferences)
            return
        }

        if navigationAction.targetFrame?.isMainFrame == true { onMainFrameRequest?(navigationAction.request) }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Check if this is a download (Content-Disposition: attachment or non-renderable MIME)
        if let response = navigationResponse.response as? HTTPURLResponse {
            let contentDisposition = response.value(forHTTPHeaderField: "Content-Disposition") ?? ""
            if contentDisposition.lowercased().hasPrefix("attachment") {
                decisionHandler(.download)
                return
            }
        }

        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }

        decisionHandler(.allow)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Recover from a web content process crash by reloading.
        webView.reload()
    }

    // MARK: - Download Handling

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.register(download, from: webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.register(download, from: webView)
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Handle window.open(): open in new tab
        if let url = navigationAction.request.url {
            onNewTabRequested?(url, true)
        }
        return nil
    }

    // MARK: - Drops

    // ui delegate spi: whether the page (or webkit's own load) took a drop. if nothing did, dawn opens it.
    @objc(_webView:didPerformDragOperation:)
    func webView(_ webView: WKWebView, didPerformDragOperation handled: Bool) {
        guard let dawn = webView as? DawnWebView, let dropped = dawn.dropFinished(handled: handled) else { return }
        onDropOpen?(dropped)
    }

    // MARK: - Context Menus

    // webkit's ui delegate spi for macos context menus: it hands over its proposed menu with a hit test
    // of what was clicked, and shows whatever menu comes back. if a future webkit drops it, webkit's
    // own menu simply shows instead.
    @objc(_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:)
    func webView(_ webView: WKWebView, getContextMenuFromProposedMenu menu: NSMenu, forElement element: NSObject, userInfo: NSObject?, completionHandler: @escaping (NSMenu?) -> Void) {
        guard showsContextMenus else {
            completionHandler(nil)
            return
        }
        let actions = ContextMenuActions(
            webView: webView,
            openInNewTab: { [weak self] url in self?.onNewTabRequested?(url, true) },
            openInNewWindow: { [weak self] url in self?.onNewWindowRequested?(url) }
        )
        completionHandler(ContextMenuBuilder.menu(from: menu, element: element, actions: actions))
    }

    // downloads started by webkit's own context menu items
    @objc(_webView:contextMenuDidCreateDownload:)
    func webView(_ webView: WKWebView, contextMenuDidCreateDownload download: WKDownload) {
        DownloadManager.shared.register(download, from: webView)
    }
}
