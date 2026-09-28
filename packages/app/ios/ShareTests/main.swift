import Foundation

let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let inbox = ShareInbox(root: root)
func check(_ condition: Bool, _ message: String) {
  if !condition { fatalError(message) }
}
func rejects(_ body: () throws -> Void) {
  do { try body(); fatalError("Expected rejection") } catch { }
}
check(try inbox.takeNext() == nil, "Empty inbox")
try inbox.publishTargets([["id": "project:a:b", "label": "App · Mac"]])
check(try inbox.targets().first?["label"] == "App · Mac", "Project labels round trip")
try inbox.save(data: Data([1, 2]), name: "first.png", mimeType: "image/png", target: "project:a:b")
try inbox.save(data: Data([3]), name: "second.txt", mimeType: "text/plain", target: nil)
let first = try inbox.takeNext()!
check(first["name"] == "first.png" && first["shortcutId"] == "project:a:b", "FIFO / target")
check(Data(base64Encoded: first["data"]!) == Data([1, 2]), "Bytes preserved")
check(try inbox.takeNext()?["name"] == "second.txt", "Second share preserved")
check(try inbox.takeNext() == nil, "Shares consumed once")
rejects { try inbox.save(data: Data(count: ShareInbox.maxBytes + 1), name: "big", mimeType: "x", target: nil) }
let file = root.appendingPathComponent("file.bin")
try Data(count: ShareInbox.maxBytes).write(to: file)
check(try ShareInbox.readFile(file).count == ShareInbox.maxBytes, "Boundary allowed")
try Data(count: ShareInbox.maxBytes + 1).write(to: file)
rejects { _ = try ShareInbox.readFile(file) }
rejects { _ = try ShareInbox.readFile(root) }
for _ in 0..<20 { try inbox.save(data: Data([1]), name: "file", mimeType: "x", target: nil) }
rejects { try inbox.save(data: Data([1]), name: "overflow", mimeType: "x", target: nil) }
for _ in 0..<20 { _ = try inbox.takeNext() }
let invalid = root.appendingPathComponent("ShareInbox/invalid.json")
try Data("invalid".utf8).write(to: invalid)
rejects { _ = try inbox.takeNext() }
check(try inbox.takeNext() == nil, "Corrupt entry does not block queue")
print("iOS share inbox checks passed")
