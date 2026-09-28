import BridgeDesktopUI
import XCTest

final class BridgeDesktopNativeSessionDirectoryPresentationTests: XCTestCase {
  func testSelectsAvailableNativeProvidersAndPreservesDirectoryState() {
    let prior = BridgeDesktopNativeSessionDirectoryState(
      projectID: "project",
      installationID: "qoder",
      selectedSessionID: "session",
      isOpen: true,
      statusMessage: "Ready"
    )
    let state = BridgeDesktopNativeSessionDirectoryPresentation.state(
      candidates: [
        candidate("pi", provider: "pi"),
        candidate("disabled", provider: "qoder", enabled: false),
        candidate("unavailable", provider: "qoder", availability: "missing"),
        candidate("other", provider: "opencode"),
        candidate("qoder", provider: "qoder"),
      ],
      prior: prior
    )

    XCTAssertEqual(state.installations.map(\.installationID), ["pi", "qoder"])
    XCTAssertEqual(state.projectID, "project")
    XCTAssertEqual(state.installationID, "qoder")
    XCTAssertEqual(state.selectedSessionID, "session")
    XCTAssertTrue(state.isOpen)
    XCTAssertEqual(state.statusMessage, "Ready")
  }

  private func candidate(
    _ id: String,
    provider: String,
    enabled: Bool = true,
    availability: String = "available"
  ) -> BridgeDesktopNativeSessionInstallationCandidate {
    BridgeDesktopNativeSessionInstallationCandidate(
      installationID: id,
      providerID: provider,
      displayName: id,
      region: nil,
      isEnabled: enabled,
      availability: availability
    )
  }
}
