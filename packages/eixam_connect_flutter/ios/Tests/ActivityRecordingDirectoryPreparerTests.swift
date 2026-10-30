import Foundation
import Darwin

/// Run with swiftc alongside Classes/ActivityRecordingDirectoryPreparer.swift.
/// Real iOS SQLite/inherited-backup behavior is covered by the native harness.
@main
struct ActivityRecordingDirectoryPreparerTests {
  private struct ExpectedFailure: Error {}

  static func main() throws {
    setbuf(stdout, nil)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var passed = 0
    func expect(_ condition: Bool) { precondition(condition) }
    func test(_ name: String, _ action: (URL) throws -> Void) throws {
      let support = root.appendingPathComponent(name, isDirectory: true)
      try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
      print("RUN \(name)")
      try action(support)
      passed += 1
      print("PASS \(name)")
    }
    func mustFail(_ action: () throws -> Void) {
      do { try action(); fatalError("Expected preparation failure") } catch {}
    }

    try test("create-application-support-subtree") { support in
      let p = ActivityRecordingDirectoryPreparer(applicationSupport: { support })
      let directory = try p.prepare()
      precondition(directory.path == support.appendingPathComponent("eixam/activity_recordings").path)
      precondition(FileManager.default.fileExists(atPath: directory.path))
      expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }
    try test("existing-metadata-is-not-moved-or-reset") { support in
      let directory = support.appendingPathComponent("eixam/activity_recordings", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let file = directory.appendingPathComponent("recordings.sqlite")
      let bytes = Data("existing metadata".utf8)
      try bytes.write(to: file)
      let prepared = try ActivityRecordingDirectoryPreparer(applicationSupport: { support }).prepare()
      precondition(prepared.path == directory.path)
      expect(try Data(contentsOf: file) == bytes)
    }
    try test("reapply-after-directory-recreation") { support in
      let p = ActivityRecordingDirectoryPreparer(applicationSupport: { support })
      let first = try p.prepare()
      try FileManager.default.removeItem(at: first)
      let recreated = try p.prepare()
      expect(try recreated.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }
    try test("setter-failure-fails-closed") { support in
      mustFail {
        _ = try ActivityRecordingDirectoryPreparer(
          applicationSupport: { support }, setExcluded: { _ in throw ExpectedFailure() }
        ).prepare()
      }
    }
    try test("readback-false-fails-closed") { support in
      mustFail {
        _ = try ActivityRecordingDirectoryPreparer(
          applicationSupport: { support }, setExcluded: { _ in }, isExcluded: { _ in false }
        ).prepare()
      }
    }
    try test("readback-error-fails-closed") { support in
      mustFail {
        _ = try ActivityRecordingDirectoryPreparer(
          applicationSupport: { support }, isExcluded: { _ in throw ExpectedFailure() }
        ).prepare()
      }
    }
    try test("support-resolution-failure-fails-closed") { _ in
      mustFail {
        _ = try ActivityRecordingDirectoryPreparer(applicationSupport: { throw ExpectedFailure() }).prepare()
      }
    }
    try test("directory-creation-failure-preserves-file") { support in
      let file = support.appendingPathComponent("eixam")
      try Data("evidence".utf8).write(to: file)
      mustFail { _ = try ActivityRecordingDirectoryPreparer(applicationSupport: { support }).prepare() }
      expect(try String(contentsOf: file, encoding: .utf8) == "evidence")
    }
    print("\(passed) native Foundation tests passed")
  }
}
