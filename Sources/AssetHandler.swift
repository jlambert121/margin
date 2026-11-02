import Cocoa
import OSLog
import UniformTypeIdentifiers
import WebKit

final class AssetHandler: NSObject, WKURLSchemeHandler {
    var root: URL?
    private let imageMIMEs = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml", "avif": "image/avif", "heic": "image/heic", "bmp": "image/bmp", "tif": "image/tiff", "tiff": "image/tiff", "ico": "image/x-icon"]
    func readAsset(_ requestURL: URL) throws -> (Data, String) {
        guard let root, requestURL.host == "local" else { throw URLError(.fileDoesNotExist) }
        let candidate = root.appendingPathComponent(String(requestURL.path.dropFirst())).standardizedFileURL.resolvingSymlinksInPath()
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(canonicalRoot.path + "/"),
              let mime = imageMIMEs[candidate.pathExtension.lowercased()],
              let data = try? Data(contentsOf: candidate)
        else {
            throw URLError(.noPermissionsToReadFile)
        }
        return (data, mime)
    }

    func webView(_: WKWebView, start task: WKURLSchemeTask) {
        do {
            guard let url = task.request.url else { throw URLError(.badURL) }
            let (data, mime) = try readAsset(url)
            task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
            task.didReceive(data)
            task.didFinish()
        } catch { task.didFailWithError(error) }
    }

    func webView(_: WKWebView, stop _: WKURLSchemeTask) {}
}
