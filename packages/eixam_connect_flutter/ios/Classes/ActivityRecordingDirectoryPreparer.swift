import Foundation

/// Foundation-only recording policy, independently testable without Flutter.
final class ActivityRecordingDirectoryPreparer {
  private let applicationSupport: () throws -> URL
  private let setExcluded: (URL) throws -> Void
  private let isExcluded: (URL) throws -> Bool
  private let fileManager: FileManager

  init(
    fileManager: FileManager = .default,
    applicationSupport: @escaping () throws -> URL = {
      try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true
      )
    },
    setExcluded: @escaping (URL) throws -> Void = { directory in
      var url = directory
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try url.setResourceValues(values)
    },
    isExcluded: @escaping (URL) throws -> Bool = { directory in
      var url = directory
      url.removeAllCachedResourceValues()
      return try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        .isExcludedFromBackup == true
    }
  ) {
    self.fileManager = fileManager
    self.applicationSupport = applicationSupport
    self.setExcluded = setExcluded
    self.isExcluded = isExcluded
  }

  func prepare() throws -> URL {
    let root = try applicationSupport().resolvingSymlinksInPath()
    let directory = root.appendingPathComponent("eixam/activity_recordings", isDirectory: true)
    guard directory.resolvingSymlinksInPath().path == directory.path else {
      throw PreparationFailure()
    }
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let children = try fileManager.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]
    )
    guard try children.allSatisfy({
      try $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false
    }) else {
      throw PreparationFailure()
    }
    // A directory exclusion controls all descendants, including files SQLite
    // creates later. Reapply and read back on every preparation/recreation.
    try setExcluded(directory)
    guard try isExcluded(directory) else { throw PreparationFailure() }
    return directory
  }

  private struct PreparationFailure: Error {}
}
