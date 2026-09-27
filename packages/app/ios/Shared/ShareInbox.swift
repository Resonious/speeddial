import Foundation

/// Each producer publishes an immutable file with an atomic rename. The app is
/// the only consumer; its bridge serializes reads. No credentials are shared.
struct ShareInbox {
  static let groupID = "group.sh.speeddial.speeddialApp"
  static let maxBytes = 8 * 1024 * 1024
  let root: URL

  init(root: URL) { self.root = root }

  static func shared() throws -> ShareInbox {
    guard let root = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: groupID
    ) else { throw ShareFailure("Shared storage is unavailable. Check App Group signing.") }
    return ShareInbox(root: root)
  }

  private var directory: URL { root.appendingPathComponent("ShareInbox", isDirectory: true) }

  func publishTargets(_ targets: [[String: String]]) throws {
    let data = try JSONSerialization.data(withJSONObject: targets)
    try data.write(to: root.appendingPathComponent("share-targets.json"), options: .atomic)
  }

  func targets() throws -> [[String: String]] {
    let url = root.appendingPathComponent("share-targets.json")
    if !FileManager.default.fileExists(atPath: url.path) { return [] }
    guard let targets = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
      as? [[String: String]] else { throw ShareFailure("Could not read project list.") }
    return targets
  }

  static func readFile(_ url: URL) throws -> Data {
    guard url.isFileURL else { throw ShareFailure("The shared item is not a local file.") }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else { throw ShareFailure("Share a file, not a folder.") }
    guard (values.fileSize ?? 0) <= maxBytes else {
      throw ShareFailure("Shared files must be 8 MiB or smaller.")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
    guard data.count <= maxBytes else { throw ShareFailure("Shared files must be 8 MiB or smaller.") }
    return data
  }

  func save(data: Data, name: String, mimeType: String, target: String?) throws {
    guard data.count <= Self.maxBytes else { throw ShareFailure("Shared files must be 8 MiB or smaller.") }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard try entries().count < 20 else {
      throw ShareFailure("Open SpeedDial and attach or dismiss earlier shares before sharing more.")
    }
    var payload = ["name": name, "mimeType": mimeType, "data": data.base64EncodedString()]
    payload["shortcutId"] = target
    let bytes = try JSONSerialization.data(withJSONObject: payload)
    let filename = String(format: "%020.0f", Date().timeIntervalSince1970 * 1_000_000)
      + "-" + UUID().uuidString + ".json"
    #if os(iOS)
    let options: Data.WritingOptions = [.atomic, .completeFileProtection]
    #else
    let options: Data.WritingOptions = [.atomic]
    #endif
    try bytes.write(to: directory.appendingPathComponent(filename), options: options)
  }

  private func entries() throws -> [URL] {
    if !FileManager.default.fileExists(atPath: directory.path) { return [] }
    return try FileManager.default.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  /// The Dart store holds one imported file until it is attached or dismissed,
  /// just as on Android. Remaining shares stay on disk until requested.
  func takeNext() throws -> [String: String]? {
    guard let url = try entries().first else { return nil }
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    guard (values.fileSize ?? 0) <= 12 * 1024 * 1024 else {
      try FileManager.default.removeItem(at: url)
      throw ShareFailure("The saved share is too large.")
    }
    // A locked device or transient IO failure must leave the entry queued.
    let bytes = try Data(contentsOf: url)
    let payload: [String: String]
    do {
      guard let decoded = try JSONSerialization.jsonObject(with: bytes)
        as? [String: String], let encoded = decoded["data"],
        let data = Data(base64Encoded: encoded), data.count <= Self.maxBytes else {
        throw ShareFailure("The saved share could not be read.")
      }
      payload = decoded
    } catch {
      try FileManager.default.removeItem(at: url)
      throw error
    }
    try FileManager.default.removeItem(at: url)
    return payload
  }
}

struct ShareFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
