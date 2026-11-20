import BridgeIPC
import Foundation

public enum CompleteServiceExitError: LocalizedError, Sendable {
  case busy(String)
  case failed(String)
  case invalidResponse

  public var errorDescription: String? {
    switch self {
    case .busy(let message), .failed(let message): message
    case .invalidResponse: "后台服务返回了无法识别的退出状态。"
    }
  }
}

/// Waits for accepted requests to drain; it never asks the service to force-cancel work.
public enum CompleteServiceExit {
  public static func prepare(using client: any BridgeServiceClientProtocol) async throws {
    while true {
      try Task.checkCancellation()
      let response = try await client.providerGateway(
        IPCProviderGatewayRequest(action: "service.prepareCompleteExit"))
      let status = try JSONDecoder().decode(Status.self, from: Data(response.resultJSON.utf8))
      switch status.state {
      case "waiting":
        try await Task.sleep(for: .seconds(1))
      case "ready":
        return
      case "busy":
        throw CompleteServiceExitError.busy(status.message ?? "仍有任务或审批正在进行，请完成后重试。")
      case "failed":
        throw CompleteServiceExitError.failed(status.message ?? "后台服务未能完成退出准备。")
      default:
        throw CompleteServiceExitError.invalidResponse
      }
    }
  }

  private struct Status: Decodable {
    let state: String
    let message: String?
  }
}
