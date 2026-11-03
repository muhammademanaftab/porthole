import Foundation
import PortholeCore

private func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("porthole-config-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func decodeConfig(_ s: String) -> HostConfig? { try? JSONDecoder().decode(HostConfig.self, from: Data(s.utf8)) }

func hostConfigTests() {
    let old = decodeConfig(#"{"password":"p","apiKey":"k","apiSecret":"s"}"#)
    expect("config: file without ports decodes with 7878 and 7880", old,
           HostConfig(password: "p", apiKey: "k", apiSecret: "s", httpPort: 7878, livekitPort: 7880))
    expect("config: ports in the file are kept",
           decodeConfig(#"{"password":"p","apiKey":"k","apiSecret":"s","httpPort":9000,"livekitPort":9100}"#)?.livekitPort, 9100)
    check("config: missing password is rejected", decodeConfig(#"{"apiKey":"k","apiSecret":"s"}"#) == nil)
    check("config: out-of-range http port is rejected",
          decodeConfig(#"{"password":"p","apiKey":"k","apiSecret":"s","httpPort":70000}"#) == nil)

    let fresh = HostConfig.fresh()
    check("config: fresh password is 12 chars, key is PH plus 8, secret is 43, default ports",
          fresh.password.count == 12 && fresh.apiKey.hasPrefix("PH") && fresh.apiKey.count == 10
          && fresh.apiSecret.count == 43 && fresh.httpPort == 7878 && fresh.livekitPort == 7880)

    let fm = FileManager.default
    let dir = tempDir().appendingPathComponent("Porthole")
    defer { try? fm.removeItem(at: dir.deletingLastPathComponent()) }
    let file = dir.appendingPathComponent("config.json")
    let created = HostConfig.load(in: dir)
    check("config: first launch creates the directory and file, no backup", fm.fileExists(atPath: file.path) && created.backup == nil)
    expect("config: new file is readable only by the owner",
           (try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions] as? Int, 0o600)
    expect("config: second launch reads the same config", HostConfig.load(in: dir).config, created.config)

    let legacy = Data(#"{"password":"keep-me","apiKey":"PHold","apiSecret":"old-secret"}"#.utf8)
    try? legacy.write(to: file)
    let upgraded = HostConfig.load(in: dir)
    check("config: legacy file without ports keeps its password and secret",
          upgraded.config.password == "keep-me" && upgraded.config.apiSecret == "old-secret" && upgraded.backup == nil)
    expect("config: legacy file is not rewritten", try? Data(contentsOf: file), legacy)

    let garbage = Data("{not json".utf8)
    try? garbage.write(to: file)
    let replaced = HostConfig.load(in: dir)
    expect("config: unreadable file is moved to config.json.bad", replaced.backup?.lastPathComponent, "config.json.bad")
    expect("config: the backup holds the original bytes", try? Data(contentsOf: dir.appendingPathComponent("config.json.bad")), garbage)
    expect("config: a new config is written in its place",
           (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(HostConfig.self, from: $0) }, replaced.config)

    try? Data("second bad".utf8).write(to: file)
    let again = HostConfig.load(in: dir)
    expect("config: an existing backup is not overwritten", again.backup?.lastPathComponent, "config.json.bad.2")
    expect("config: the first backup is untouched", try? Data(contentsOf: dir.appendingPathComponent("config.json.bad")), garbage)
}
