import BridgeAgentCore
import BridgeSecurity
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif os(Windows)
  import WinSDK
#endif

public struct DeepSeekHarnessDesktopDescriptor: Codable, Equatable, Sendable {
  public let `protocol`: String
  public let host: String
  public let port: Int
  public let profileID: String
  public let instanceID: String
  public let publicKey: String
  public let pid: Int32
  public let executablePath: String
  public let desktopVersion: String
  public let connectorVersion: String

  public static func load(path: String, installation: AgentInstallation) throws -> Self {
    let data: Data
    do {
      data = try readDescriptor(path: path)
    } catch {
      let failure = error as NSError
      if (failure.domain == NSCocoaErrorDomain
        && failure.code == CocoaError.fileReadNoSuchFile.rawValue)
        || (failure.domain == NSPOSIXErrorDomain && failure.code == 2)
      {
        throw DeepSeekHarnessDesktopRPCError(
          code: "desktop_connector_not_ready",
          message: "DSH Desktop Connector 尚未就绪。请启动 DSH 桌面；若仍无法连接，请完全退出桌面后重新安装 Connector。")
      }
      throw error
    }
    let value = try JSONDecoder().decode(Self.self, from: data)
    try value.validate(installation: installation)
    return value
  }

  private static func readDescriptor(path: String) throws -> Data {
    #if canImport(Darwin) || canImport(Glibc)
      let attributes = try FileManager.default.attributesOfItem(atPath: path)
      guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
        mode & 0o077 == 0
      else { throw SecureFileArtifactError.unsafePermissions }
    #else
      _ = try FileManager.default.attributesOfItem(atPath: path)
    #endif
    #if os(Windows)
      return try DeepSeekHarnessDesktopWindowsIdentity.readDescriptor(
        at: path, maximumBytes: 16 * 1_024)
    #else
      return try SecureFileArtifactReader.read(at: path, maximumBytes: 16 * 1_024)
    #endif
  }

  public func validate(installation: AgentInstallation) throws {
    guard self.protocol == "codex-bridge-dsh/1", host == "127.0.0.1",
      (1...65_535).contains(port), pid > 1,
      [profileID, instanceID].allSatisfy({
        !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\n")
      }), Data(base64Encoded: publicKey)?.count == 32,
      [.deepSeekHarness, .deepSeekHarnessDesktop].contains(installation.providerID),
      let runningPath = Self.processPath(pid),
      AgentPathSemantics.isContained(runningPath, in: executablePath),
      AgentPathSemantics.isContained(executablePath, in: runningPath)
    else { throw AgentRuntimeError.unsupportedProtocol("dsh_desktop_identity") }
    let installed = URL(fileURLWithPath: installation.executablePath)
      .resolvingSymlinksInPath().standardizedFileURL
    let runtime = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().standardizedFileURL
    let components = installed.pathComponents
    if let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) {
      let bundle = NSString.path(withComponents: Array(components.prefix(appIndex + 1)))
      guard AgentPathSemantics.isContained(runtime.path, in: bundle) else {
        throw AgentRuntimeError.installationUnavailable(installation.id)
      }
    } else {
      guard
        AgentPathSemantics.isContained(runtime.path, in: installed.deletingLastPathComponent().path)
      else { throw AgentRuntimeError.installationUnavailable(installation.id) }
    }
    _ = try SecureFileArtifactSnapshot.capture(at: installed.path, requiresExecutable: true)
    _ = try SecureFileArtifactSnapshot.capture(at: runtime.path, requiresExecutable: true)
  }

  public var isRunning: Bool {
    guard let path = Self.processPath(pid) else { return false }
    return AgentPathSemantics.isContained(path, in: executablePath)
      && AgentPathSemantics.isContained(executablePath, in: path)
  }

  private static func processPath(_ pid: Int32) -> String? {
    #if canImport(Darwin)
      var info = proc_bsdinfo()
      let size = Int32(MemoryLayout<proc_bsdinfo>.size)
      guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
        info.pbi_uid == getuid()
      else { return nil }
      var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
      let count = buffer.withUnsafeMutableBytes {
        proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
      }
      guard count > 0 else { return nil }
      return String(cString: buffer)
    #elseif canImport(Glibc)
      var metadata = stat()
      guard stat("/proc/\(pid)", &metadata) == 0, metadata.st_uid == getuid() else { return nil }
      return try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe")
    #elseif os(Windows)
      return DeepSeekHarnessDesktopWindowsIdentity.processPath(pid)
    #else
      return nil
    #endif
  }
}
