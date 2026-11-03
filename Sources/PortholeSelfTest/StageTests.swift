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

    let listed = [(1920, 1080, 1920, 1080), (4096, 2304, 8192, 4608), (1920, 1080, 3840, 2160), (2048, 1152, 4096, 2304)]
    expect("headless stage picks 1920x1080 at 2x so Screen Sharing looks normal", StageLayout.headlessMode(listed), 2)
    expect("headless stage never picks the 1x 1920x1080 mode", StageLayout.headlessMode([(1920, 1080, 1920, 1080), (2048, 1152, 4096, 2304)]), 1)
    expect("headless stage falls back to the largest 2x mode", StageLayout.headlessMode([(4096, 2304, 8192, 4608), (2048, 1152, 4096, 2304)]), 0)
    expect("headless stage with no 2x mode gives nil", StageLayout.headlessMode([(1920, 1080, 1920, 1080)]), nil)
}
