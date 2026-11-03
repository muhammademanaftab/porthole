import CoreGraphics

public enum StageLayout {
    public static let pixels = CGSize(width: 8192, height: 4608)
    public static let points = CGSize(width: 4096, height: 2304)
    public static let pixelsPerInch: CGFloat = 218
    public static let topMargin: CGFloat = 64
    public static let cascadeStep: CGFloat = 48
    public static let cascadeSlots = 8

    public static var sizeInMillimeters: CGSize {
        CGSize(width: (pixels.width / pixelsPerInch * 25.4).rounded(), height: (pixels.height / pixelsPerInch * 25.4).rounded())
    }

    public static func origin(besides displays: [CGRect]) -> CGPoint {
        guard let first = displays.first else { return .zero }
        let all = displays.dropFirst().reduce(first) { $0.union($1) }
        return CGPoint(x: all.maxX, y: all.maxY - 1)
    }

    public static func slot(_ index: Int, stage: CGRect, window: CGSize) -> CGPoint {
        let step = CGFloat(((index % cascadeSlots) + cascadeSlots) % cascadeSlots) * cascadeStep
        let x = min(stage.minX + step, max(stage.minX, stage.maxX - window.width))
        let y = min(stage.minY + topMargin + step, max(stage.minY + topMargin, stage.maxY - window.height))
        return CGPoint(x: x, y: y)
    }

    public static func isHiDPIStageMode(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int) -> Bool {
        width > 0 && height > 0 && pixelWidth == width * 2 && pixelHeight == height * 2
    }

    public static func bestMode(_ modes: [(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int)]) -> Int? {
        modes.indices
            .filter { isHiDPIStageMode(width: modes[$0].width, height: modes[$0].height, pixelWidth: modes[$0].pixelWidth, pixelHeight: modes[$0].pixelHeight) }
            .max { modes[$0].width * modes[$0].height < modes[$1].width * modes[$1].height }
    }
}
