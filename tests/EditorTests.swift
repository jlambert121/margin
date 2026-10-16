import Cocoa
import WebKit

// Runs a test script in the real editor page. The bridge suite runs the page in
// native mode, against a handler that only needs to exist.
final class MessageSink: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
}

final class Suite: NSObject, WKNavigationDelegate {
    let view: WKWebView
    let root: URL
    let testFile: String
    private var finished: (([[String: Any]]) -> Void)?
    init(root: URL, testFile: String, nativeBridge: Bool) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if nativeBridge {
            configuration.userContentController.add(MessageSink(), name: "native")
            let setup = try! String(contentsOf: root.appendingPathComponent("tests/bridge.setup.js"), encoding: .utf8)
            configuration.userContentController.addUserScript(WKUserScript(source: setup, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1180, height: 780), configuration: configuration)
        self.root = root; self.testFile = testFile
        super.init()
        view.navigationDelegate = self
    }
    func run(_ finished: @escaping ([[String: Any]]) -> Void) {
        self.finished = finished
        view.loadFileURL(root.appendingPathComponent("web/index.html"), allowingReadAccessTo: root)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let script = try! String(contentsOf: root.appendingPathComponent(testFile), encoding: .utf8)
        webView.callAsyncJavaScript("return await \(script)", arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .failure(let error): fputs("\(self.testFile): \(error)\n", stderr); exit(1)
            case .success(let value): self.finished?(value as? [[String: Any]] ?? [])
            }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fputs("Navigation failed: \(error)\n", stderr); exit(1) }
}

func report(_ results: [[String: Any]]) -> Bool {
    for result in results { print("\(result["passed"] as? Bool == true ? "PASS" : "FAIL") \(result["name"] ?? "") \(result["error"] ?? "")") }
    return !results.isEmpty && results.allSatisfy { $0["passed"] as? Bool == true }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let editorSuite = Suite(root: root, testFile: "tests/editor.test.js", nativeBridge: false)
let bridgeSuite = Suite(root: root, testFile: "tests/bridge.test.js", nativeBridge: true)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780), styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = editorSuite.view
window.orderBack(nil)
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { fputs("Editor tests timed out\n", stderr); exit(1) }
editorSuite.run { editorResults in
    let editorPassed = report(editorResults)
    editorSuite.view.takeSnapshot(with: nil) { image, error in
        if let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: output) }
        else { fputs("Screenshot unavailable: \(String(describing: error))\n", stderr) }
        bridgeSuite.run { bridgeResults in
            let bridgePassed = report(bridgeResults)
            exit(editorPassed && bridgePassed ? 0 : 1)
        }
    }
}
app.run()
