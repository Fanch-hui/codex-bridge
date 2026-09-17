#if os(Windows)
  import BridgeSecurity
  import Foundation

  enum CodexWindowsPackagedRuntimeError: Error, Equatable, Sendable, LocalizedError {
    case localAppDataUnavailable
    case invalidPackageDirectory
    case copyFailed
    case integrityCheckFailed
    case publishFailed

    var errorDescription: String? {
      switch self {
      case .localAppDataUnavailable:
        "Codex runtime cache needs a writable local application data directory."
      case .invalidPackageDirectory:
        "The installed Codex package has an invalid runtime directory."
      case .copyFailed:
        "The installed Codex CLI could not be copied to its runtime cache."
      case .integrityCheckFailed:
        "The cached Codex CLI failed its integrity check."
      case .publishFailed:
        "The cached Codex CLI could not be published atomically."
      }
    }
  }

  enum CodexWindowsPackagedRuntime {
    private static let preparationLock = NSLock()
    private static let companionNames = [
      "codex-command-runner.exe",
      "codex-windows-sandbox-setup.exe",
      "codex-code-mode-host.exe",
      "rg.exe",
      "THIRD_PARTY_NOTICES.txt",
    ]
    private static let copyBufferSize = 64 * 1_024

    static func executableCopyIfPackaged(
      at executableURL: URL,
      environment: [String: String]
    ) throws -> URL? {
      try withPreparationLock {
        guard let resourcesDirectory = packagedResourcesDirectory(for: executableURL) else {
          return nil
        }
        let packageRoot =
          resourcesDirectory
          .deletingLastPathComponent()
          .deletingLastPathComponent()
        let targetDirectory = try cacheDirectory(
          for: packageRoot,
          environment: environment
        )
        return try prepareCopy(
          at: executableURL,
          resourcesDirectory: resourcesDirectory,
          targetDirectory: targetDirectory
        )
      }
    }

    static func executableCopyIfPackaged(
      at executableURL: URL,
      resourcesDirectory: URL,
      targetDirectory: URL
    ) throws -> URL? {
      try withPreparationLock {
        try prepareCopy(
          at: executableURL,
          resourcesDirectory: resourcesDirectory,
          targetDirectory: targetDirectory
        )
      }
    }

    private static func packagedResourcesDirectory(for executableURL: URL) -> URL? {
      CodexWindowsPackageDiscovery.installationDirectories().first { root in
        let expected = CodexWindowsPath.join(root, "app", "resources", "codex.exe")
        return CodexWindowsPath.equivalent(executableURL.path, expected)
      }.map { root in
        URL(
          fileURLWithPath: CodexWindowsPath.join(root, "app", "resources"),
          isDirectory: true
        )
      }
    }

    private static func cacheDirectory(
      for packageRoot: URL,
      environment: [String: String]
    ) throws -> URL {
      guard let packageName = CodexWindowsPath.basename(packageRoot.path), !packageName.isEmpty
      else {
        throw CodexWindowsPackagedRuntimeError.invalidPackageDirectory
      }
      guard let localAppData = localAppData(in: environment) else {
        throw CodexWindowsPackagedRuntimeError.localAppDataUnavailable
      }
      return URL(
        fileURLWithPath: CodexWindowsPath.join(
          localAppData,
          "CodexBridge",
          "Runtime",
          "Codex",
          packageName
        ),
        isDirectory: true
      )
    }

    private static func localAppData(in environment: [String: String]) -> String? {
      if let value = CodexWindowsPath.environmentValue("LOCALAPPDATA", in: environment) {
        return CodexWindowsPath.normalize(value)
      }
      guard let profile = CodexWindowsPath.userProfile(in: environment) else { return nil }
      return CodexWindowsPath.normalize(CodexWindowsPath.join(profile, "AppData", "Local"))
    }

    private static func prepareCopy(
      at executableURL: URL,
      resourcesDirectory: URL,
      targetDirectory: URL
    ) throws -> URL? {
      let sourceExecutable = resourcesDirectory.appendingPathComponent("codex.exe")
      guard CodexWindowsPath.equivalent(executableURL.path, sourceExecutable.path) else {
        return nil
      }

      let artifacts = try sourceArtifacts(in: resourcesDirectory)
      let targetExecutable = targetDirectory.appendingPathComponent("codex.exe")
      if cacheMatches(artifacts, in: targetDirectory) {
        return targetExecutable
      }

      let fileManager = FileManager.default
      do {
        try fileManager.createDirectory(
          at: targetDirectory.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        let stagingDirectory = targetDirectory.deletingLastPathComponent().appendingPathComponent(
          ".codex-\(UUID().uuidString.lowercased())-staging",
          isDirectory: true
        )
        defer { try? fileManager.removeItem(at: stagingDirectory) }
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
        for artifact in artifacts {
          let destination = stagingDirectory.appendingPathComponent(artifact.name)
          try copyFile(from: artifact.source, to: destination)
          try verify(destination, matches: artifact.snapshot)
        }
        try publish(stagingDirectory, at: targetDirectory)
        return targetExecutable
      } catch let error as CodexWindowsPackagedRuntimeError {
        throw error
      } catch {
        throw CodexWindowsPackagedRuntimeError.copyFailed
      }
    }

    private struct Artifact {
      let name: String
      let source: URL
      let snapshot: SecureFileArtifactSnapshot
      let requiresExecutable: Bool
    }

    private static func sourceArtifacts(in resourcesDirectory: URL) throws -> [Artifact] {
      var names = ["codex.exe"]
      let fileManager = FileManager.default
      names.append(
        contentsOf: companionNames.filter { name in
          fileManager.fileExists(atPath: resourcesDirectory.appendingPathComponent(name).path)
        })
      return try names.map { name in
        let source = resourcesDirectory.appendingPathComponent(name)
        let requiresExecutable = name.lowercased().hasSuffix(".exe")
        return Artifact(
          name: name,
          source: source,
          snapshot: try SecureFileArtifactSnapshot(
            capturing: source.path,
            requiresExecutable: requiresExecutable
          ),
          requiresExecutable: requiresExecutable
        )
      }
    }

    private static func cacheMatches(_ artifacts: [Artifact], in directory: URL) -> Bool {
      artifacts.allSatisfy { artifact in
        let target = directory.appendingPathComponent(artifact.name)
        guard FileManager.default.fileExists(atPath: target.path) else { return false }
        guard
          let snapshot = try? SecureFileArtifactSnapshot(
            capturing: target.path,
            requiresExecutable: artifact.requiresExecutable
          )
        else {
          return false
        }
        return snapshot.sha256 == artifact.snapshot.sha256
      }
    }

    private static func copyFile(from source: URL, to destination: URL) throws {
      let input = try FileHandle(forReadingFrom: source)
      defer { try? input.close() }
      guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
        throw CodexWindowsPackagedRuntimeError.copyFailed
      }
      let output = try FileHandle(forWritingTo: destination)
      defer { try? output.close() }
      while let chunk = try input.read(upToCount: copyBufferSize), !chunk.isEmpty {
        try output.write(contentsOf: chunk)
      }
      try output.synchronize()
    }

    private static func verify(_ path: URL, matches source: SecureFileArtifactSnapshot) throws {
      guard
        let target = try? SecureFileArtifactSnapshot(
          capturing: path.path,
          requiresExecutable: path.path.lowercased().hasSuffix(".exe")
        ),
        target.sha256 == source.sha256
      else {
        throw CodexWindowsPackagedRuntimeError.integrityCheckFailed
      }
    }

    private static func publish(_ staging: URL, at target: URL) throws {
      let fileManager = FileManager.default
      do {
        if fileManager.fileExists(atPath: target.path) {
          _ = try fileManager.replaceItemAt(
            target,
            withItemAt: staging,
            backupItemName: nil,
            options: []
          )
        } else {
          try fileManager.moveItem(at: staging, to: target)
        }
      } catch {
        throw CodexWindowsPackagedRuntimeError.publishFailed
      }
    }

    private static func withPreparationLock<Result>(
      _ body: () throws -> Result
    ) rethrows -> Result {
      preparationLock.lock()
      defer { preparationLock.unlock() }
      return try body()
    }
  }
#endif
