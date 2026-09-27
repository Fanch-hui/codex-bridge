import BridgeAgentCore
import BridgeSecurity
import Foundation
import Testing

@testable import BridgePiRPC

struct PiExecutableResolverTests {
  @Test func resolvesOfficialNPMPackageEntryThroughCapturedNode() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pi-resolver-\(UUID().uuidString)", isDirectory: true)
    let package = directory.appendingPathComponent(
      "node_modules/@earendil-works/pi-coding-agent", isDirectory: true)
    let entry = package.appendingPathComponent("dist/bundle/cli.js")
    try FileManager.default.createDirectory(
      at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"name":"@earendil-works/pi-coding-agent","bin":{"pi":"dist/bundle/cli.js"}}"#.utf8)
      .write(to: package.appendingPathComponent("package.json"))
    try Data("process.exit(0)".utf8).write(to: entry)
    defer { try? FileManager.default.removeItem(at: directory) }

    let executable = try SecureFileArtifactSnapshot.capture(at: entry.path)
    let nodePath = directory.appendingPathComponent("node").path
    let node = try SecureFileArtifactSnapshot(
      canonicalPath: nodePath, device: 1, inode: 1, fileSize: 1,
      modificationTimeNanoseconds: 0, sha256: String(repeating: "a", count: 64))
    let result = try PiExecutableResolver.resolve(executable: executable, node: node)

    #expect(result.executableArgv == [nodePath, executable.canonicalPath])
    #expect(result.artifacts.map(\.role) == [.runtimeManifest, .dependencyLock])
    #expect(
      result.artifacts.last?.canonicalPath
        == resolvedPath(package.appendingPathComponent("package.json")))
  }

  @Test func resolvesPNPMGlobalVersionPackageFromItsShimDirectory() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pi-pnpm-resolver-\(UUID().uuidString)", isDirectory: true)
    let shim = directory.appendingPathComponent("pnpm/pi.cmd")
    let package = directory.appendingPathComponent(
      "pnpm/global/5/node_modules/@mariozechner/pi-coding-agent", isDirectory: true)
    let entry = package.appendingPathComponent("dist/cli.js")
    try FileManager.default.createDirectory(
      at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("shim".utf8).write(to: shim)
    try Data(
      #"{"name":"@mariozechner/pi-coding-agent","bin":{"pi":"dist/cli.js"}}"#.utf8
    ).write(to: package.appendingPathComponent("package.json"))
    try Data("process.exit(0)".utf8).write(to: entry)
    defer { try? FileManager.default.removeItem(at: directory) }

    let executable = try SecureFileArtifactSnapshot.capture(at: shim.path)
    let nodePath = directory.appendingPathComponent("node").path
    let node = try SecureFileArtifactSnapshot(
      canonicalPath: nodePath, device: 1, inode: 1, fileSize: 1,
      modificationTimeNanoseconds: 0, sha256: String(repeating: "a", count: 64))
    let result = try PiExecutableResolver.resolve(executable: executable, node: node)

    #expect(result.executableArgv == [nodePath, resolvedPath(entry)])
    #expect(
      result.artifacts.last?.canonicalPath
        == resolvedPath(package.appendingPathComponent("package.json")))
  }

  private func resolvedPath(_ url: URL) -> String {
    let path = url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
    #if os(Windows)
      return AgentPathSemantics.canonicalPath(path, style: .windows) ?? path
    #else
      return path
    #endif
  }
}
