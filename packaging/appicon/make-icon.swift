// Regenerate the macOS app icon from packaging/appicon/DNSwitch.svg.
//   swift packaging/appicon/make-icon.swift
// Renders the SVG with WebKit (same engine as Safari, so gradients/filters come
// out exactly as authored), then lays it out on Apple's icon grid: the artwork
// body occupies 824/1024 = 80.5% of the canvas, centred, rest transparent. A
// full-bleed icon would render visibly larger than every system icon next to it.
import AppKit
import WebKit

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let svgURL = repo.appendingPathComponent("packaging/appicon/DNSwitch.svg")
let outDir = repo.appendingPathComponent("app/DNSwitch/Assets.xcassets/AppIcon.appiconset")
let bodyRatio: CGFloat = 824.0 / 1024.0
let master: CGFloat = 2048   // render once, big, then downsample

// (point size, scale) -> Apple's 10 macOS entries
let entries: [(Int, Int)] = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

final class Renderer: NSObject, WKNavigationDelegate {
    let web: WKWebView
    override init() {
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: master, height: master))
        super.init()
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = NSRect(x: 0, y: 0, width: master, height: master)
        cfg.snapshotWidth = NSNumber(value: Double(master))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            w.takeSnapshot(with: cfg) { img, err in
                guard let art = img else { FileHandle.standardError.write("render failed: \(err!)\n".data(using: .utf8)!); exit(1) }
                emit(art); exit(0)
            }
        }
    }
}

func emit(_ art: NSImage) {
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    // The catalog ROOT needs its own Contents.json — without it actool silently
    // treats the whole .xcassets as empty and emits no Assets.car at all.
    let root = outDir.deletingLastPathComponent().appendingPathComponent("Contents.json")
    let rootJSON: [String: Any] = ["info": ["version": 1, "author": "xcode"]]
    try! JSONSerialization.data(withJSONObject: rootJSON, options: [.prettyPrinted, .sortedKeys])
        .write(to: root)

    var images: [[String: String]] = []
    for (pt, scale) in entries {
        let px = CGFloat(pt * scale)
        // Draw into an explicitly-sized bitmap rep. NSImage.lockFocus() would
        // pick up the display's 2x backing scale and silently emit 2x-too-big
        // PNGs (actool then rejects every entry).
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(px), pixelsHigh: Int(px),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: px, height: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let body = (px * bodyRatio).rounded()
        let o = ((px - body) / 2).rounded()
        art.draw(in: NSRect(x: o, y: o, width: body, height: body),
                 from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(pt).png" : "icon_\(pt)@2x.png"
        try! rep.representation(using: .png, properties: [:])!
            .write(to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
    }
    let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
    let data = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: outDir.appendingPathComponent("Contents.json"))
    print("wrote \(entries.count) PNGs + Contents.json to \(outDir.path)")
}

let svg = try! String(contentsOf: svgURL, encoding: .utf8)
let html = """
<html><head><style>html,body{margin:0;padding:0;background:transparent}
svg{width:\(Int(master))px;height:\(Int(master))px;display:block}</style></head><body>\(svg)</body></html>
"""
let r = Renderer()
r.web.loadHTMLString(html, baseURL: nil)
app.run()
