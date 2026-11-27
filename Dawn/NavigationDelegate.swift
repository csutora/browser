import AppKit
import UniformTypeIdentifiers
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

    // a page the page opens itself (window.open, a link to a new window) has to be shown in a web view
    // made from webkit's configuration and returned to it, or it loses its tie to its opener: sign-in
    // windows then can't report back. given the url and whether it should come to the front.
    var onOpenPage: ((WKWebViewConfiguration, URL?, Bool) -> WKWebView?)?
    // the page closed itself (only pages opened by script may)
    var onClose: (() -> Void)?
    var onDialog: ((PageDialog) -> Void)?
    var onAuthenticate: ((URLAuthenticationChallenge, @escaping (URLCredential?) -> Void) -> Void)?

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

        // links with a download attribute (including blob: and data: ones)
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }

        // Cmd+click on a link opens in new tab (background). links to a new window (target="_blank")
        // go on to createWebViewWith, which opens them, cmd or not.
        if navigationAction.targetFrame != nil, navigationAction.navigationType == .linkActivated && navigationAction.modifierFlags.contains(.command) {
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

    // a new window the page opens becomes a tab, whatever size it asked for: dawn's windows are tabs
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = navigationAction.request.url.flatMap { $0.absoluteString.isEmpty ? nil : $0 }
        let foreground = !navigationAction.modifierFlags.contains(.command)
        if let onOpenPage { return onOpenPage(configuration, url, foreground) }
        if let url { onNewTabRequested?(url, foreground) }
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        onClose?()
    }

    // MARK: - Dialogs

    // who's asking: the frame's origin, which a page can't fake, rather than anything the page says
    private static func asker(_ frame: WKFrameInfo) -> String {
        let origin = frame.securityOrigin
        guard !origin.host.isEmpty else { return "This page says" }
        return (origin.port == 0 ? origin.host : "\(origin.host):\(origin.port)") + " says"
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let onDialog else { return completionHandler() }
        onDialog(PageDialog(title: Self.asker(frame), message: message, cancelTitle: nil) { _, _ in completionHandler() })
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let onDialog else { return completionHandler(false) }
        onDialog(PageDialog(title: Self.asker(frame), message: message) { confirmed, _ in completionHandler(confirmed) })
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard let onDialog else { return completionHandler(nil) }
        onDialog(PageDialog(title: Self.asker(frame), message: prompt, fields: [.text(placeholder: "", value: defaultText ?? "")]) { confirmed, values in
            completionHandler(confirmed ? values.first : nil)
        })
    }

    // http authentication: the site (or a proxy) asks for a username and password before it answers.
    // anything else (certificates) is left to webkit.
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let asksForPassword = [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM]
            .contains(challenge.protectionSpace.authenticationMethod)
        guard asksForPassword, let onAuthenticate else { return completionHandler(.performDefaultHandling, nil) }
        // declining goes on without credentials, which shows whatever the site sends to those who can't sign in
        onAuthenticate(challenge) { credential in
            completionHandler(credential == nil ? .performDefaultHandling : .useCredential, credential)
        }
    }

    // MARK: - File Uploads

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard let window = webView.window, window.attachedSheet == nil else { return completionHandler(nil) }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.prompt = "Choose"
        let types = Self.acceptedTypes(parameters)
        if !types.isEmpty, !parameters.allowsDirectories { panel.allowedContentTypes = types }
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    // the types the input accepts (its accept attribute), as webkit works them out from its mime types
    // and extensions, so only those can be picked, like safari. webkit has no public call for it: without
    // it, any file can be picked, which the page checks anyway.
    private static func acceptedTypes(_ parameters: WKOpenPanelParameters) -> [UTType] {
        let key = "_allowedFileExtensions"
        guard parameters.responds(to: NSSelectorFromString(key)), let extensions = parameters.value(forKey: key) as? [String] else { return [] }
        return extensions.compactMap { UTType(filenameExtension: $0) }
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
