import BridgeIPC
import XCTest

final class ServiceClientProtocolFallbackTests: XCTestCase {
  func testDefaultsFailClosedWhenTheyCannotForwardRequestedOptions() async {
    let client = TestBridgeServiceClient()

    do {
      _ = try await client.agentModels(installationID: "install-1", projectID: "project-1")
      XCTFail("Expected project-scoped model lookup to require an implementation")
    } catch let error as BridgeServiceClientError {
      XCTAssertEqual(error, .unavailable)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    do {
      _ = try await client.connectAgentInstallation(
        providerID: "qoder",
        baseURL: nil,
        apiKey: nil,
        alwaysProceedConfirmed: false,
        qoderDistribution: "cn",
        installationID: "qoder-cn"
      )
      XCTFail("Expected Qoder connection options to require an implementation")
    } catch let error as BridgeServiceClientError {
      XCTAssertEqual(error, .unavailable)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let modelQueries = await client.agentModelsQueriesValue()
    let connectionRequest = await client.agentConnectionRequest()
    XCTAssertEqual(modelQueries, [])
    XCTAssertNil(connectionRequest)
  }
}
