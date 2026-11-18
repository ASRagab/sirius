// Prints an HTML file to a paginated PDF with the system's WebKit.
//   swift print-pdf.swift <in.html> <out.pdf>
// US Letter, 0.75 in margins. WKWebView.createPDF would give one endless
// page, so this runs a print operation that saves to a file, with no panels.

import AppKit
import WebKit

final class Printer: NSObject, WKNavigationDelegate {
    let output: URL
    let window: NSWindow
    let web: WKWebView

    init(input: URL, output: URL) {
        self.output = output
        let frame = NSRect(x: 0, y: 0, width: 612, height: 792)
        web = WKWebView(frame: frame)
        // A print operation needs its view in a window, on screen or not.
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        super.init()
        web.navigationDelegate = self
        web.loadFileURL(input, allowingReadAccessTo: input.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 54
        info.bottomMargin = 54
        info.leftMargin = 54
        info.rightMargin = 54
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: self,
                           didRun: #selector(done(_:success:contextInfo:)), contextInfo: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("couldn't load the page: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail("couldn't load the page: \(error.localizedDescription)")
    }

    @objc func done(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if success { exit(0) }
        fail("the print operation failed")
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("print-pdf: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fail("usage: print-pdf.swift <in.html> <out.pdf>") }
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let printer = Printer(input: URL(fileURLWithPath: arguments[1]), output: URL(fileURLWithPath: arguments[2]))
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { fail("timed out") }
application.run()
