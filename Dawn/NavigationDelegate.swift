import AppKit
import WebKit

// MARK: - Navigation Delegate (handles navigation policies, new tabs, downloads)
class NavigationDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// Callback when a new tab is requested. Bool indicates whether to switch focus.
    var onNewTabRequested: ((URL, Bool) -> Void)?

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // target="_blank" or window.open() — targetFrame is nil
        if navigationAction.targetFrame == nil {
            onNewTabRequested?(url, true)
            decisionHandler(.cancel)
            return
        }

        // Cmd+click on a link opens in new tab (background)
        if navigationAction.navigationType == .linkActivated && navigationAction.modifierFlags.contains(.command) {
            onNewTabRequested?(url, false)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
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
        download.delegate = DownloadHandler.shared
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = DownloadHandler.shared
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Handle window.open() — open in new tab
        if let url = navigationAction.request.url {
            onNewTabRequested?(url, true)
        }
        return nil
    }
}

// MARK: - Download Handler
class DownloadHandler: NSObject, WKDownloadDelegate {
    static let shared = DownloadHandler()

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            completionHandler(nil)
            return
        }

        let destinationURL = uniqueURL(for: suggestedFilename, in: downloadsDir)
        completionHandler(destinationURL)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        // TODO: Wire up to download manager UI when implemented
    }

    func downloadDidFinish(_ download: WKDownload) {
        // TODO: Wire up to download manager UI when implemented
    }

    private func uniqueURL(for filename: String, in directory: URL) -> URL {
        let fileManager = FileManager.default
        var url = directory.appendingPathComponent(filename)

        if !fileManager.fileExists(atPath: url.path) {
            return url
        }

        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension

        var counter = 1
        while fileManager.fileExists(atPath: url.path) {
            let newFilename = ext.isEmpty ? "\(name) (\(counter))" : "\(name) (\(counter)).\(ext)"
            url = directory.appendingPathComponent(newFilename)
            counter += 1
        }

        return url
    }
}
