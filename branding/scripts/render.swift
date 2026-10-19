// Draws every HiveMinds brand asset from one set of shapes, so the icon, the mark and the SVGs never drift apart.
// Run from the repo root: branding/scripts/render.sh
import AppKit

// MARK: Palette

struct RGB {
    let r, g, b: CGFloat
    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }
    func cg(_ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var hex: String { String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255)) }
}

let honeyLight = RGB(0xFFD37A)
let honey = RGB(0xF5B53D)
let honeyDeep = RGB(0xE8922A)
let tileTop = RGB(0x1C1C1F)
let tileBottom = RGB(0x050506)
let white = RGB(0xFFFFFF)

// MARK: Geometry

/// The mark: seven pointy-top hexagons in a honeycomb. The lit centre cell is the mind; the six around it are agents.
struct Mark {
    let center: CGPoint
    let cell: CGFloat      // circumradius of one cell
    let gap: CGFloat
    let corner: CGFloat

    var cellCenters: [CGPoint] {
        let d = sqrt(3) * cell + gap
        return [center] + (0..<6).map { i in
            let a = CGFloat(i) * .pi / 3
            return CGPoint(x: center.x + d * cos(a), y: center.y + d * sin(a))
        }
    }
}

/// Corners of a pointy-top hexagon, clockwise from the top in a y-down space.
func hexVertices(_ c: CGPoint, _ r: CGFloat) -> [CGPoint] {
    (0..<6).map { i in
        let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 3
        return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
    }
}

/// Where the rounded corner at vertex `i` starts and ends (a 120° corner, so the tangent points sit r/√3 from it).
func cornerPoints(_ v: [CGPoint], _ i: Int, _ radius: CGFloat) -> (CGPoint, CGPoint) {
    let p = v[i], prev = v[(i + 5) % 6], next = v[(i + 1) % 6]
    let t = radius / sqrt(3)
    func toward(_ q: CGPoint) -> CGPoint {
        let dx = q.x - p.x, dy = q.y - p.y, len = hypot(dx, dy)
        return CGPoint(x: p.x + dx / len * t, y: p.y + dy / len * t)
    }
    return (toward(prev), toward(next))
}

func hexPath(_ c: CGPoint, _ r: CGFloat, corner: CGFloat) -> CGPath {
    let v = hexVertices(c, r)
    let path = CGMutablePath()
    let (start, _) = cornerPoints(v, 0, corner)
    path.move(to: start)
    for i in 0..<6 {
        path.addArc(tangent1End: v[i], tangent2End: v[(i + 1) % 6], radius: corner)
    }
    path.closeSubpath()
    return path
}

func hexSVG(_ c: CGPoint, _ r: CGFloat, corner: CGFloat) -> String {
    let v = hexVertices(c, r)
    func f(_ p: CGPoint) -> String { String(format: "%.2f %.2f", p.x, p.y) }
    var d = "M\(f(cornerPoints(v, 0, corner).0))"
    for i in 0..<6 {
        let (a, b) = cornerPoints(v, i, corner)
        d += " L\(f(a)) A\(String(format: "%.2f", corner)) \(String(format: "%.2f", corner)) 0 0 1 \(f(b))"
    }
    return d + " Z"
}

/// The macOS icon grid: an 824pt rounded square inside a 1024pt canvas.
let canvas: CGFloat = 1024
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius: CGFloat = 185
let iconMark = Mark(center: CGPoint(x: 512, y: 512), cell: 96, gap: 22, corner: 18)

// MARK: Raster drawing

func render(size: Int, draw: (CGContext, CGFloat) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let scale = CGFloat(size) / canvas
    // Work in a 1024pt, y-down space so the drawing matches the SVGs.
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: scale, y: -scale)
    draw(ctx, scale)
    return rep.representation(using: .png, properties: [:])!
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func drawMark(_ ctx: CGContext, _ m: Mark, onTile: Bool) {
    let centers = m.cellCenters
    // Agents: graphite cells, barely lifted off black, with a faint top edge.
    for c in centers.dropFirst() {
        let p = hexPath(c, m.cell, corner: m.corner)
        ctx.saveGState()
        ctx.addPath(p); ctx.clip()
        linear(ctx, [white.cg(0.15), white.cg(0.07)],
               from: CGPoint(x: c.x, y: c.y - m.cell), to: CGPoint(x: c.x, y: c.y + m.cell))
        ctx.restoreGState()
        ctx.addPath(p)
        ctx.setStrokeColor(white.cg(0.12)); ctx.setLineWidth(2)
        ctx.strokePath()
    }
    // The mind: one honey cell with a soft glow.
    let c = centers[0]
    let p = hexPath(c, m.cell, corner: m.corner)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: onTile ? 90 : 60, color: honey.cg(0.55))
    ctx.addPath(p); ctx.setFillColor(honey.cg()); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(p); ctx.clip()
    linear(ctx, [honeyLight.cg(), honeyDeep.cg()],
           from: CGPoint(x: c.x, y: c.y - m.cell), to: CGPoint(x: c.x, y: c.y + m.cell))
    ctx.restoreGState()
}

func drawIcon(_ ctx: CGContext, _ scale: CGFloat) {
    let tile = CGPath(roundedRect: tileRect, cornerWidth: tileRadius, cornerHeight: tileRadius, transform: nil)
    // Drop shadow under the tile, like system icons.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10 * scale), blur: 28 * scale, color: CGColor(gray: 0, alpha: 0.5))
    ctx.addPath(tile); ctx.setFillColor(tileBottom.cg()); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    linear(ctx, [tileTop.cg(), tileBottom.cg()], from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
    drawMark(ctx, iconMark, onTile: true)
    ctx.restoreGState()
    // Hairline edge so the tile reads on a black Dock.
    ctx.addPath(CGPath(roundedRect: tileRect.insetBy(dx: 1.5, dy: 1.5), cornerWidth: tileRadius - 1.5,
                       cornerHeight: tileRadius - 1.5, transform: nil))
    ctx.setStrokeColor(white.cg(0.10)); ctx.setLineWidth(3)
    ctx.strokePath()
}

/// The mark alone, scaled to fill the canvas, for use inside the app or on dark backgrounds.
let soloMark = Mark(center: CGPoint(x: 512, y: 512), cell: 150, gap: 34, corner: 28)

// MARK: SVG

func iconSVG() -> String {
    let m = iconMark
    let outer = m.cellCenters.dropFirst().map {
        "<path d=\"\(hexSVG($0, m.cell, corner: m.corner))\" fill=\"url(#cell)\" stroke=\"#FFFFFF\" stroke-opacity=\"0.12\" stroke-width=\"2\"/>"
    }.joined(separator: "\n    ")
    let core = hexSVG(m.center, m.cell, corner: m.corner)
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
      <defs>
        <linearGradient id="tile" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="\(tileTop.hex)"/><stop offset="1" stop-color="\(tileBottom.hex)"/></linearGradient>
        <linearGradient id="cell" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0.15"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0.07"/></linearGradient>
        <linearGradient id="honey" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="\(honeyLight.hex)"/><stop offset="1" stop-color="\(honeyDeep.hex)"/></linearGradient>
        <filter id="glow" x="-1" y="-1" width="3" height="3"><feGaussianBlur stdDeviation="45"/></filter>
        <clipPath id="clip"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
      </defs>
      <g clip-path="url(#clip)">
        <rect x="100" y="100" width="824" height="824" fill="url(#tile)"/>
        \(outer)
        <path d="\(core)" fill="\(honey.hex)" opacity="0.55" filter="url(#glow)"/>
        <path d="\(core)" fill="url(#honey)"/>
      </g>
      <rect x="101.5" y="101.5" width="821" height="821" rx="183.5" fill="none" stroke="#FFFFFF" stroke-opacity="0.10" stroke-width="3"/>
    </svg>

    """
}

/// Flat mark: one colour for the agents, honey for the mind. `agents` lets it work on dark or light backgrounds.
func markSVG(agents: String, agentsOpacity: Double) -> String {
    let m = soloMark
    let outer = m.cellCenters.dropFirst().map {
        "<path d=\"\(hexSVG($0, m.cell, corner: m.corner))\" fill=\"\(agents)\" fill-opacity=\"\(agentsOpacity)\"/>"
    }.joined(separator: "\n  ")
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
      \(outer)
      <path d="\(hexSVG(m.center, m.cell, corner: m.corner))" fill="\(honey.hex)"/>
    </svg>

    """
}

/// Mark plus name. The type is SF Pro (the system font), so it renders as intended on a Mac.
func wordmarkSVG(text: String, agents: String, agentsOpacity: Double) -> String {
    let s: CGFloat = 0.25  // mark scaled from 1024 to 256
    let m = Mark(center: CGPoint(x: 128, y: 128), cell: soloMark.cell * s, gap: soloMark.gap * s, corner: soloMark.corner * s)
    let outer = m.cellCenters.dropFirst().map {
        "<path d=\"\(hexSVG($0, m.cell, corner: m.corner))\" fill=\"\(agents)\" fill-opacity=\"\(agentsOpacity)\"/>"
    }.joined(separator: "\n  ")
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 840 256" width="840" height="256">
      \(outer)
      <path d="\(hexSVG(m.center, m.cell, corner: m.corner))" fill="\(honey.hex)"/>
      <text x="262" y="170" fill="\(text)" font-family="SF Pro Display, -apple-system, BlinkMacSystemFont, Inter, Helvetica Neue, sans-serif" font-size="116" font-weight="600" letter-spacing="-2">Hive<tspan fill-opacity="0.6">Minds</tspan></text>
    </svg>

    """
}

// MARK: Output

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "branding")
func write(_ data: Data, _ rel: String) {
    let url = root.appendingPathComponent(rel)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
}

// App icon set (iconutil turns this into HiveMinds.icns).
for pt in [16, 32, 128, 256, 512] {
    write(render(size: pt, draw: drawIcon), "icon/HiveMinds.iconset/icon_\(pt)x\(pt).png")
    write(render(size: pt * 2, draw: drawIcon), "icon/HiveMinds.iconset/icon_\(pt)x\(pt)@2x.png")
}
write(render(size: 1024, draw: drawIcon), "icon/icon-1024.png")
write(render(size: 1024) { ctx, _ in drawMark(ctx, soloMark, onTile: false) }, "logo/mark-1024.png")

write(Data(iconSVG().utf8), "icon/icon.svg")
write(Data(markSVG(agents: "#FFFFFF", agentsOpacity: 0.16).utf8), "logo/mark-dark.svg")
write(Data(markSVG(agents: "#000000", agentsOpacity: 0.14).utf8), "logo/mark-light.svg")
write(Data(wordmarkSVG(text: "#F2F2F2", agents: "#FFFFFF", agentsOpacity: 0.16).utf8), "logo/wordmark-dark.svg")
write(Data(wordmarkSVG(text: "#0A0A0A", agents: "#000000", agentsOpacity: 0.14).utf8), "logo/wordmark-light.svg")
print("Rendered brand assets into \(root.path)")
