import CoreGraphics
import PortholeCore

func stageTests() {
    expect("stage is 8192x4608 pixels", StageLayout.pixels, CGSize(width: 8192, height: 4608))
    expect("stage points are half its pixels", StageLayout.points, CGSize(width: StageLayout.pixels.width / 2, height: StageLayout.pixels.height / 2))
    expect("stage physical size matches 218 ppi", StageLayout.sizeInMillimeters, CGSize(width: 954, height: 537))

    expect("no displays puts the stage at zero", StageLayout.origin(besides: []), .zero)
    expect("stage sits right of a single display, overlapping its bottom row",
           StageLayout.origin(besides: [CGRect(x: 0, y: 0, width: 1920, height: 1080)]), CGPoint(x: 1920, y: 1079))
    expect("stage sits beyond the union of several displays",
           StageLayout.origin(besides: [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: -1440, y: -900, width: 1440, height: 2000)]),
           CGPoint(x: 1920, y: 1099))

    let stage = CGRect(x: 1920, y: 1079, width: 4096, height: 2304)
    let small = CGSize(width: 800, height: 600)
    expect("first slot is the stage corner below the top margin", StageLayout.slot(0, stage: stage, window: small), CGPoint(x: 1920, y: 1079 + 64))
    expect("slots cascade by 48 points", StageLayout.slot(2, stage: stage, window: small), CGPoint(x: 1920 + 96, y: 1079 + 64 + 96))
    expect("slots wrap after eight", StageLayout.slot(8, stage: stage, window: small), StageLayout.slot(0, stage: stage, window: small))
    expect("negative slot index wraps instead of going off-stage", StageLayout.slot(-1, stage: stage, window: small), StageLayout.slot(7, stage: stage, window: small))
    expect("a window near stage size is pulled back so it fits",
           StageLayout.slot(7, stage: stage, window: CGSize(width: 4000, height: 2200)), CGPoint(x: 1920 + 96, y: 1079 + 104))
    expect("a window larger than the stage stays at the corner",
           StageLayout.slot(5, stage: stage, window: CGSize(width: 5000, height: 3000)), CGPoint(x: 1920, y: 1079 + 64))

    check("2x mode is HiDPI", StageLayout.isHiDPIStageMode(width: 4096, height: 2304, pixelWidth: 8192, pixelHeight: 4608))
    check("1x mode is not HiDPI", !StageLayout.isHiDPIStageMode(width: 4096, height: 2304, pixelWidth: 4096, pixelHeight: 2304))
    check("zero-size mode is not HiDPI", !StageLayout.isHiDPIStageMode(width: 0, height: 0, pixelWidth: 0, pixelHeight: 0))
    expect("best mode is the largest HiDPI one",
           StageLayout.bestMode([(8192, 4608, 8192, 4608), (2048, 1152, 4096, 2304), (4096, 2304, 8192, 4608), (1920, 1080, 1920, 1080)]), 2)
    expect("no HiDPI mode gives nil", StageLayout.bestMode([(1920, 1080, 1920, 1080)]), nil)

    let mbp = StageLayout.viewerMode(screenPoints: CGSize(width: 1470, height: 956))
    expect("stage follows a MacBook Air screen at 2x", mbp.points, CGSize(width: 1470, height: 956))
    expect("stage pixels are twice its points", mbp.pixels, CGSize(width: 2940, height: 1912))
    expect("a 1920x1080 viewer gives a 3840x2160 stage", StageLayout.viewerMode(screenPoints: CGSize(width: 1920, height: 1080)).pixels, CGSize(width: 3840, height: 2160))
    expect("no viewer size keeps the 4096x2304 canvas", StageLayout.viewerMode(screenPoints: nil).points, CGSize(width: 4096, height: 2304))
    expect("a zero viewer size keeps the default canvas", StageLayout.viewerMode(screenPoints: .zero).pixels, StageLayout.pixels)
    let huge = StageLayout.viewerMode(screenPoints: CGSize(width: 6016, height: 3384))
    check("a huge viewer is capped at 8192x4608 pixels", huge.pixels.width <= 8192 && huge.pixels.height <= 4608)
    check("capping keeps the aspect ratio", abs(huge.pixels.width / huge.pixels.height - 6016.0 / 3384.0) < 0.01)
    let endless = StageLayout.viewerMode(screenPoints: CGSize(width: 1e308, height: 1e308))
    check("an absurd viewer size is capped instead of overflowing", endless.pixels.width <= 8192 && endless.pixels.height <= 4608 && endless.pixels.width >= 1024)
    check("an infinite viewer size is capped too", StageLayout.viewerMode(screenPoints: CGSize(width: Double.infinity, height: 900)).pixels.width <= 8192)
    expect("screen size: a viewer's size is bounded", StageLayout.screenSize(width: 1e308, height: 900), CGSize(width: StageLayout.maxScreenPoints, height: 900))
    expect("screen size: NaN or missing means no size", StageLayout.screenSize(width: Double.nan, height: 900), nil)
    expect("screen size: under one point means no size", StageLayout.screenSize(width: 0, height: 900), nil)
    let tiny = StageLayout.viewerMode(screenPoints: CGSize(width: 320, height: 240))
    check("a tiny viewer is raised to at least 1024x768 pixels", tiny.pixels.width >= 1024 && tiny.pixels.height >= 768)
    check("pixel sizes are multiples of 4 so points stay even", Int(mbp.pixels.width) % 4 == 0 && Int(mbp.pixels.height) % 4 == 0)

    check("a stage in use is never released", !StageLayout.shouldRelease(emptySince: nil, now: 10_000))
    check("an empty stage stays for 10 minutes", !StageLayout.shouldRelease(emptySince: 1000, now: 1599))
    check("an empty stage is released after 10 minutes", StageLayout.shouldRelease(emptySince: 1000, now: 1600))
}
