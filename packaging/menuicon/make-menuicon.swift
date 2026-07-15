// Regenerate the menu-bar template icons from the two witch SVGs.
//   swift packaging/menuicon/make-menuicon.swift
// Renders each SVG with WebKit, crops to the shared art bounds (so the hat sits
// in the SAME place whether or not the "on" stars are present — no jump on
// toggle), fits it into a 20×18pt box, and writes 1x/2x/3x template PNGs into
// two imagesets. Template rendering = the menu bar owns the colour (black on a
// light bar, auto-inverted to white on a dark bar); the SVG's own fill is
// irrelevant. The menu-bar glyph is a DIFFERENT thing from the app icon.
import AppKit
import WebKit

// Anchor on this file's location (packaging/menuicon/), not the cwd — otherwise
// running from elsewhere writes a stray Assets.xcassets under the wrong dir before
// it crashes on the missing SVG (Fable NIT-4). make-appicon.sh does the same.
let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let outRoot = repo.appendingPathComponent("app/DNSwitch/Assets.xcassets")
let master: CGFloat = 1024
let boxW: CGFloat = 20, boxH: CGFloat = 18   // point box; art is height-fit, centred
let cropX: CGFloat = 0, cropY: CGFloat = 32, cropW: CGFloat = 1024, cropH: CGFloat = 960  // shared bounds (measured)

let svgs = [("MenuWitchOn", "witch-on.svg"), ("MenuWitchOff", "witch-off.svg")]

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

func rgba(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: w*4, bitsPerPixel: 32)!
}

final class R: NSObject, WKNavigationDelegate {
    let web: WKWebView; let name: String; let done: (NSBitmapImageRep) -> Void
    init(name: String, done: @escaping (NSBitmapImageRep) -> Void) {
        self.name = name; self.done = done
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: master, height: master))
        super.init(); web.navigationDelegate = self; web.setValue(false, forKey: "drawsBackground")
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = NSRect(x: 0, y: 0, width: master, height: master)
        cfg.snapshotWidth = NSNumber(value: Double(master))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            w.takeSnapshot(with: cfg) { img, err in
                guard let img else { FileHandle.standardError.write("render failed: \(err!)\n".data(using:.utf8)!); exit(1) }
                let rep = rgba(Int(master), Int(master))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                img.draw(in: NSRect(x: 0, y: 0, width: master, height: master))
                NSGraphicsContext.restoreGraphicsState()
                self.done(rep)
            }
        }
    }
}

func emit(_ name: String, _ full: NSBitmapImageRep) {
    let dir = outRoot.appendingPathComponent("\(name).imageset")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let art = NSImage(size: NSSize(width: master, height: master)); art.addRepresentation(full)
    // WebKit renders y-down; our crop rect is in that space. Flip for AppKit draw.
    for scale in [1, 2, 3] {
        let pxW = Int(boxW * CGFloat(scale)), pxH = Int(boxH * CGFloat(scale))
        let rep = rgba(pxW, pxH)
        NSGraphicsContext.saveGraphicsState()
        let gc = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = gc
        gc.imageInterpolation = .high
        // fit cropH into boxH, centre horizontally
        let s = (boxH * CGFloat(scale)) / cropH
        let drawW = cropW * s, drawH = cropH * s
        let ox = (CGFloat(pxW) - drawW) / 2
        // source rect in the master image (AppKit origin bottom-left → flip y)
        let srcY = master - cropY - cropH
        art.draw(in: NSRect(x: ox, y: 0, width: drawW, height: drawH),
                 from: NSRect(x: cropX, y: srcY, width: cropW, height: cropH),
                 operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let fn = "\(name)_\(scale)x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(fn))
    }
    let imgs = [1,2,3].map { ["idiom":"universal","scale":"\($0)x","filename":"\(name)_\($0)x.png"] }
    let contents: [String: Any] = ["images": imgs, "info": ["version":1,"author":"xcode"],
                                   "properties": ["template-rendering-intent":"template"]]
    try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted,.sortedKeys])
        .write(to: dir.appendingPathComponent("Contents.json"))
    print("wrote \(name).imageset")
}

// root Contents.json (actool treats the catalog as empty without it)
try? FileManager.default.createDirectory(at: outRoot, withIntermediateDirectories: true)
try! JSONSerialization.data(withJSONObject: ["info":["version":1,"author":"xcode"]], options: [.prettyPrinted, .sortedKeys])
    .write(to: outRoot.appendingPathComponent("Contents.json"))

var pending = svgs.count
var renderers: [R] = []
for (name, file) in svgs {
    let svg = try! String(contentsOf: repo.appendingPathComponent("packaging/menuicon/\(file)"), encoding: .utf8)
    let html = "<html><head><style>html,body{margin:0;padding:0;background:transparent}svg{width:\(Int(master))px;height:\(Int(master))px;display:block}</style></head><body>\(svg)</body></html>"
    let r = R(name: name) { rep in emit(name, rep); pending -= 1; if pending == 0 { exit(0) } }
    renderers.append(r)
    r.web.loadHTMLString(html, baseURL: nil)
}
app.run()
