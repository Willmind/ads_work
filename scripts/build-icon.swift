import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("用法：swift scripts/build-icon.swift <输出目录>\n", stderr)
    exit(1)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let outline: [CGPoint] = [
    CGPoint(x: 512, y: 210), CGPoint(x: 794, y: 376), CGPoint(x: 794, y: 650),
    CGPoint(x: 512, y: 814), CGPoint(x: 230, y: 650), CGPoint(x: 230, y: 376)
]
let seams: [[CGPoint]] = [
    [CGPoint(x: 230, y: 376), CGPoint(x: 512, y: 536), CGPoint(x: 794, y: 376)],
    [CGPoint(x: 512, y: 536), CGPoint(x: 512, y: 814)],
    [CGPoint(x: 372, y: 292), CGPoint(x: 654, y: 456)]
]
func path(_ points: [CGPoint], closed: Bool = false) -> CGPath {
    let path = CGMutablePath()
    path.move(to: points[0])
    for point in points.dropFirst() { path.addLine(to: point) }
    if closed { path.closeSubpath() }
    return path
}
let cube = path(outline, closed: true)

func render(size: Int) throws -> Data {
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "AppIcon", code: 1)
    }
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)
    // Use a top-left vector coordinate system. No raster source, interpolation or shadow.
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)
    context.setShouldAntialias(true)
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.addPath(CGPath(roundedRect: CGRect(x: 96, y: 96, width: 832, height: 832),
                          cornerWidth: 180, cornerHeight: 180, transform: nil))
    context.fillPath()
    context.setFillColor(CGColor(srgbRed: 0, green: 122.0 / 255, blue: 1, alpha: 1))
    context.addPath(cube)
    context.fillPath()
    context.saveGState()
    context.addPath(cube)
    context.clip()
    context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    // Keep the box seams readable in 16 px and 32 px Finder/Dock representations.
    context.setLineWidth(max(22, 0.9 / scale))
    context.setLineJoin(.miter)
    context.setLineCap(.butt)
    for seam in seams {
        context.addPath(path(seam))
        context.strokePath()
    }
    context.restoreGState()
    guard let image = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AppIcon", code: 2)
    }
    return png
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try render(size: points * scale).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
try render(size: 1024).write(to: output.appendingPathComponent("AppIcon.png"))
try render(size: 256).write(to: output.appendingPathComponent("AppIcon-preview.png"))

func svgPath(_ points: [CGPoint], closed: Bool = false) -> String {
    let commands = points.enumerated().map { index, point in
        "\(index == 0 ? "M" : "L")\(Int(point.x)) \(Int(point.y))"
    }.joined(separator: " ")
    return commands + (closed ? " Z" : "")
}
let lines = seams.map { #"<path d="\#(svgPath($0))"/>"# }.joined(separator: "\n")
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <rect x="96" y="96" width="832" height="832" rx="180" fill="#fff"/>
  <defs><clipPath id="cube"><path d="\(svgPath(outline, closed: true))"/></clipPath></defs>
  <path d="\(svgPath(outline, closed: true))" fill="#007aff"/>
  <g clip-path="url(#cube)" fill="none" stroke="#fff" stroke-width="22" stroke-linejoin="miter">
    \(lines)
  </g>
</svg>
"""
try svg.write(to: output.appendingPathComponent("AppIcon.svg"), atomically: true, encoding: .utf8)
print("已从矢量路径生成 16–1024 px 图标：\(output.path)")
