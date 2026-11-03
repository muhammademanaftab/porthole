import CoreGraphics
import PortholeCore

private func near(_ a: CGPoint?, _ x: CGFloat, _ y: CGFloat) -> Bool {
    guard let a else { return false }
    return abs(a.x - x) < 1e-9 && abs(a.y - y) < 1e-9
}

func geometryTests() {
    let b = CGRect(x: 100, y: 50, width: 800, height: 600)
    expect("global point: centre", globalPoint(nx: 0.5, ny: 0.5, windowBounds: b), CGPoint(x: 500, y: 350))
    expect("global point: (0,0) is the window origin", globalPoint(nx: 0, ny: 0, windowBounds: b), CGPoint(x: 100, y: 50))
    expect("global point: (1,1) is the far corner", globalPoint(nx: 1, ny: 1, windowBounds: b), CGPoint(x: 900, y: 650))
    expect("global point: out of range clamps per axis", globalPoint(nx: -1, ny: 2, windowBounds: b), CGPoint(x: 100, y: 650))
    expect("global point: display left of and above the primary",
           globalPoint(nx: 0.25, ny: 0.5, windowBounds: CGRect(x: -1920, y: -200, width: 1920, height: 1080)),
           CGPoint(x: -1440, y: 340))

    let square = CGRect(x: 0, y: 0, width: 1600, height: 1600)
    let wide = CGSize(width: 1600, height: 900)
    expect("fit: wide content letterboxes in a square", fittedRect(content: wide, in: square),
           CGRect(x: 0, y: 350, width: 1600, height: 900))
    expect("fit: tall content pillarboxes in a wide view",
           fittedRect(content: CGSize(width: 900, height: 1600), in: CGRect(x: 0, y: 0, width: 1600, height: 800)),
           CGRect(x: 575, y: 0, width: 450, height: 800))
    expect("fit: small content scales up and keeps the bounds origin",
           fittedRect(content: CGSize(width: 100, height: 50), in: CGRect(x: 10, y: 20, width: 400, height: 400)),
           CGRect(x: 10, y: 120, width: 400, height: 200))
    expect("fit: same aspect fills the bounds",
           fittedRect(content: CGSize(width: 3840, height: 2400), in: CGRect(x: 0, y: 0, width: 1440, height: 900)),
           CGRect(x: 0, y: 0, width: 1440, height: 900))
    expect("fit: zero content returns the bounds", fittedRect(content: .zero, in: b), b)
    expect("fit: zero-height content returns the bounds", fittedRect(content: CGSize(width: 100, height: 0), in: b), b)
    expect("fit: negative content returns the bounds", fittedRect(content: CGSize(width: -10, height: 10), in: b), b)
    let flat = CGRect(x: 5, y: 5, width: 0, height: 100)
    expect("fit: zero-width bounds returned unchanged", fittedRect(content: wide, in: flat), flat)

    check("normalized: click on the letterbox bar is ignored", normalized(CGPoint(x: 800, y: 100), content: wide, in: square) == nil)
    check("normalized: picture centre is (0.5, 0.5)", near(normalized(CGPoint(x: 800, y: 800), content: wide, in: square), 0.5, 0.5))
    check("normalized: top-left picture edge is exactly (0, 0)", near(normalized(CGPoint(x: 0, y: 350), content: wide, in: square), 0, 0))
    check("normalized: bottom-right picture edge is exactly (1, 1)",
          near(normalized(CGPoint(x: 1600, y: 1250), content: wide, in: square), 1, 1))
    check("normalized: just above the picture is outside", normalized(CGPoint(x: 800, y: 349.9), content: wide, in: square) == nil)
    check("normalized: just below the picture is outside", normalized(CGPoint(x: 800, y: 1250.1), content: wide, in: square) == nil)
    check("normalized: unknown content size uses the whole view",
          near(normalized(CGPoint(x: 400, y: 150), content: .zero, in: CGRect(x: 0, y: 0, width: 800, height: 600)), 0.5, 0.25))
    check("normalized: zero-size view gives nil", normalized(CGPoint(x: 0, y: 0), content: wide, in: .zero) == nil)

    check("clamped: letterbox bar clamps to the top edge",
          near(clampedNormalized(CGPoint(x: 400, y: 100), content: wide, in: square), 0.25, 0))
    check("clamped: far outside clamps to (1, 1)", near(clampedNormalized(CGPoint(x: 5000, y: 5000), content: wide, in: square), 1, 1))
    check("clamped: far outside the other way clamps to (0, 0)",
          near(clampedNormalized(CGPoint(x: -5, y: -5), content: wide, in: square), 0, 0))
    let inside = CGPoint(x: 1200, y: 575)
    check("clamped: inside the picture equals normalized (0.75, 0.25)",
          normalized(inside, content: wide, in: square) == clampedNormalized(inside, content: wide, in: square)
          && near(clampedNormalized(inside, content: wide, in: square), 0.75, 0.25))
    expect("clamped: zero-size view falls back to the centre", clampedNormalized(CGPoint(x: 9, y: 9), content: wide, in: .zero),
           CGPoint(x: 0.5, y: 0.5))
}
