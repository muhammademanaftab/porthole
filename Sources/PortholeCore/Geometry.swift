import CoreGraphics

public func globalPoint(nx: Double, ny: Double, windowBounds b: CGRect) -> CGPoint {
    let cx = min(max(nx, 0), 1)
    let cy = min(max(ny, 0), 1)
    return CGPoint(x: b.minX + cx * b.width, y: b.minY + cy * b.height)
}

public func fittedRect(content: CGSize, in bounds: CGRect) -> CGRect {
    guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
    let scale = min(bounds.width / content.width, bounds.height / content.height)
    let size = CGSize(width: content.width * scale, height: content.height * scale)
    return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                  width: size.width, height: size.height)
}

public func normalized(_ p: CGPoint, content: CGSize, in bounds: CGRect) -> CGPoint? {
    let r = fittedRect(content: content, in: bounds)
    guard r.width > 0, r.height > 0 else { return nil }
    let nx = (p.x - r.minX) / r.width
    let ny = (p.y - r.minY) / r.height
    guard (0...1).contains(nx), (0...1).contains(ny) else { return nil }
    return CGPoint(x: nx, y: ny)
}
