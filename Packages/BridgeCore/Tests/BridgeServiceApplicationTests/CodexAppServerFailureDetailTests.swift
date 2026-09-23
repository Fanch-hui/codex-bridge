import BridgeCodexRPC
import BridgeMCP
import Foundation
import XCTest

@testable import BridgeServiceApplication

final class CodexAppServerFailureDetailTests: XCTestCase {
  func testUnusableConfiguredExecutableReportsTheActionableReason() async throws {
    let catalog = makeCatalog(
      appServer: CodexAppServerLocator(
        configuration: .codex(configuredPath: "/missing/codex-\(UUID().uuidString)")
      )
    )

    let failureDetail = await catalogFailureDetail(catalog)
    let detail = try XCTUnwrap(failureDetail)
    XCTAssertTrue(detail.contains("Codex connection card"), detail)
    XCTAssertFalse(
      detail.contains("/CodexBridge/Unavailable/codex"),
      "The internal sentinel executable must not be reported as the launch target: \(detail)"
    )
  }

  func testLaunchFailureReportsTheExecutableAndStandardError() async throws {
    let catalog = makeCatalog(
      appServer: CodexAppServerLocator(
        configuration: AppServerConfiguration(
          executableURL: URL(fileURLWithPath: "/bin/sh"),
          arguments: ["-c", "echo 'codex: cannot execute the configured binary' >&2; exit 3"]
        )
      )
    )

    let failureDetail = await catalogFailureDetail(catalog)
    let detail = try XCTUnwrap(failureDetail)
    XCTAssertTrue(detail.contains("/bin/sh"), detail)
    XCTAssertTrue(detail.contains("cannot execute the configured binary"), detail)
  }

  private func makeCatalog(appServer: CodexAppServerLocator) -> ServiceCodexCatalog {
    ServiceCodexCatalog(
      configuration: ServiceCodexCatalogConfiguration(
        appServer: appServer,
        clientInfo: .bridge(version: "codex-app-server-detail-tests"),
        requestTimeoutNanoseconds: 1_000_000_000
      )
    )
  }

  private func catalogFailureDetail(_ catalog: ServiceCodexCatalog) async -> String? {
    do {
      _ = try await catalog.listModels(deadline: .now.advanced(by: .seconds(10)))
      XCTFail("The catalog must fail when its app-server cannot serve requests.")
      return nil
    } catch let error as BridgeMCPQueryError {
      guard case .codexAppServerUnavailable(let detail) = error else {
        XCTFail("Expected a detailed app-server failure, got \(error)")
        return nil
      }
      return detail
    } catch {
      XCTFail("Expected an app-server failure, got \(error)")
      return nil
    }
  }
}
