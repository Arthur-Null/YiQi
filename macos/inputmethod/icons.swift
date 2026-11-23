// C6: 一炁输入法的菜单栏图标（单色模板）与应用图标，用「炁」字绘制。
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let glyph = "炁"

func font(_ size: CGFloat) -> NSFont {
    NSFont(name: "PingFangSC-Semibold", size: size) ?? NSFont.systemFont(ofSize: size, weight: .semibold)
}

func drawGlyph(in rect: CGRect, size: CGFloat, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font(size), .foregroundColor: color]
    let s = NSAttributedString(string: glyph, attributes: attrs)
    let b = s.size()
    s.draw(at: CGPoint(x: rect.midX - b.width / 2, y: rect.midY - b.height / 2 + size * 0.04))
}

// C6: 菜单栏图标：圆角方框 + 字，黑色模板，由系统按菜单栏配色着色
func menuIcon() {
    let size = CGSize(width: 18, height: 18)
    var box = CGRect(origin: .zero, size: size)
    let data = NSMutableData()
    let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let r = box.insetBy(dx: 1, dy: 1)
    let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
    path.lineWidth = 1.3
    NSColor.black.setStroke()
    path.stroke()
    drawGlyph(in: r, size: 11.5, color: .black)
    ctx.endPDFPage()
    ctx.closePDF()
    data.write(to: out.appendingPathComponent("yiqi.pdf"), atomically: true)
}

// C6: 应用图标：绿色圆角方块 + 白字
func appIcon(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let r = CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let path = NSBezierPath(roundedRect: r, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: NSColor(red: 0.42, green: 0.78, blue: 0.58, alpha: 1),
               ending: NSColor(red: 0.27, green: 0.63, blue: 0.45, alpha: 1))!.draw(in: path, angle: -90)
    drawGlyph(in: r, size: s * 0.5, color: .white)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

menuIcon()
let set = out.appendingPathComponent("YiQi.iconset")
try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! appIcon(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! appIcon(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
