import Foundation

messageTests()
modifierTests()
mouseAndTextTests()
geometryTests()
tokenTests()
webRouteTests()
networkTests()
captureTests()
labelTests()

let total = Harness.passed + Harness.failed
print(Harness.failed == 0 ? "\nAll \(total) checks passed." : "\n\(Harness.failed) of \(total) check(s) failed.")
exit(Harness.failed == 0 ? 0 : 1)
