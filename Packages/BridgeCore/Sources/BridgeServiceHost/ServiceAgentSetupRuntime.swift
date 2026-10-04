import BridgeAgentCore
import Foundation

public struct ServiceAgentSetupRuntime: Codable, Equatable, Sendable {
  public let executablePath: String
  public let nodeExecutablePath: String?
  public let sdkRoot: String?
  public let version: String?
  public let installationDirectory: String

  public init(
    executablePath: String, nodeExecutablePath: String? = nil, sdkRoot: String? = nil,
    version: String? = nil, installationDirectory: String
  ) {
    self.executablePath = executablePath
    self.nodeExecutablePath = nodeExecutablePath
    self.sdkRoot = sdkRoot
    self.version = version
    self.installationDirectory = installationDirectory
  }
}

public protocol ServiceAgentSetupInstalling: Sendable {
  func prepare(
    providerID: AgentProviderID, distribution: QoderDistribution?, root: URL,
    existingExecutable: String?, report: @escaping @Sendable (String) async -> Void
  ) async throws -> ServiceAgentSetupRuntime
}

enum ServiceAgentSetupInstallError: Error, LocalizedError, Sendable {
  case unsupported(String)
  case invalidMetadata(String)
  case checksumMismatch
  case commandFailed(String)
  case unavailableExecutable

  var errorDescription: String? {
    switch self {
    case .unsupported(let message): message
    case .invalidMetadata(let source): "官方安装信息无效：\(source)"
    case .checksumMismatch: "下载文件完整性校验失败，请重试。"
    case .commandFailed(let command): "安装步骤失败：\(command)"
    case .unavailableExecutable: "安装程序未生成可用的运行入口。"
    }
  }
}
