import Foundation

enum Harness {
    static var passed = 0
    static var failed = 0
}

func check(_ name: String, _ ok: @autoclosure () -> Bool) {
    if ok() { Harness.passed += 1; print("PASS  \(name)") } else { Harness.failed += 1; print("FAIL  \(name)") }
}

func expect<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
    if actual == expected { Harness.passed += 1; print("PASS  \(name)") } else {
        Harness.failed += 1
        print("FAIL  \(name)\n        expected: \(expected)\n        actual:   \(actual)")
    }
}

func json(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func decodeBase64URL(_ s: String) -> Data? {
    var p = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while p.count % 4 != 0 { p += "=" }
    return Data(base64Encoded: p)
}
