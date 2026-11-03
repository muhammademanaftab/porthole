import Foundation

messageTests()
modifierTests()
mouseTests()
textTests()
resizeTests()
viewerTests()
geometryTests()
tokenTests()
hostConfigTests()
httpResponseTests()
webRouteTests()
networkTests()
sessionTests()
captureTests()
pacingTests()
labelTests()

let total = Harness.passed + Harness.failed
print(Harness.failed == 0 ? "\nAll \(total) checks passed." : "\n\(Harness.failed) of \(total) check(s) failed.")
exit(Harness.failed == 0 ? 0 : 1)
