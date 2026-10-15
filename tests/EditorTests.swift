import Cocoa
import WebKit

final class TestRunner: NSObject, WKNavigationDelegate {
    let view: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 1180, height: 780), configuration: configuration)
    }()
    let root: URL
    let output: URL
    var done = false
    init(root: URL, output: URL) {
        self.root = root; self.output = output
        super.init()
        view.navigationDelegate = self
    }
    func start() {
        view.loadFileURL(root.appendingPathComponent("web/index.html"), allowingReadAccessTo: root)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { if !self.done { fputs("Editor test timed out\n", stderr); exit(1) } }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let script = try! String(contentsOf: root.appendingPathComponent("tests/editor.test.js"), encoding: .utf8)
        webView.callAsyncJavaScript("return await \(script)", arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .failure(let error): fputs("\(error)\n", stderr); exit(1)
            case .success(let value):
                let results = value as? [[String: Any]] ?? []
                for result in results { print("\(result["passed"] as? Bool == true ? "PASS" : "FAIL") \(result["name"] ?? "") \(result["error"] ?? "")") }
                self.done = true
                let passed = !results.isEmpty && results.allSatisfy { $0["passed"] as? Bool == true }
                webView.takeSnapshot(with: nil) { image, error in
                    if let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: self.output) }
                    else { fputs("Screenshot unavailable: \(String(describing: error))\n", stderr) }
                    exit(passed ? 0 : 1)
                }
            }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fputs("Navigation failed: \(error)\n", stderr); exit(1) }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let runner = TestRunner(root: root, output: output)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780), styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = runner.view
window.orderBack(nil)
runner.start()
app.run()
