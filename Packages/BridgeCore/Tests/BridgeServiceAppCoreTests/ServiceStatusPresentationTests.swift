import BridgeMCP
import BridgeServiceAppCore
import XCTest

final class ServiceStatusPresentationTests: XCTestCase {
  func testMCPFailureMessageUsesMCPDegradationOnly() {
    let status = status(
      mcpState: "failed",
      degradations: ["Tunnel: helper unavailable", "MCP: 本地凭据不可用"]
    )

    XCTAssertEqual(
      ServiceStatusPresentation.mcpFailureMessage(status: status),
      "MCP: 本地凭据不可用"
    )
  }

  func testReadyMCPDoesNotShowStaleDegradation() {
    let status = status(mcpState: "ready", degradations: ["MCP: 旧错误"])

    XCTAssertNil(ServiceStatusPresentation.mcpFailureMessage(status: status))
    XCTAssertEqual(
      ServiceStatusPresentation.connectionMessage(status: status, currentMessage: "已刷新"),
      "已刷新"
    )
  }

  func testConnectionMessagePreservesCurrentMessageAndAvoidsDuplicates() {
    let status = status(mcpState: "failed", degradations: ["MCP: 本地 MCP 启动失败"])

    XCTAssertEqual(
      ServiceStatusPresentation.connectionMessage(
        status: status,
        currentMessage: "MCP: 本地 MCP 启动失败"
      ),
      "MCP: 本地 MCP 启动失败"
    )
  }

  private func status(
    mcpState: String,
    degradations: [String]
  ) -> BridgeStatusSnapshot {
    BridgeStatusSnapshot(
      appVersion: "test",
      mcpState: mcpState,
      tunnelState: "stopped",
      executionState: "ready",
      supervisorState: "ready",
      degradations: degradations,
      pendingApprovalCount: 0
    )
  }
}
