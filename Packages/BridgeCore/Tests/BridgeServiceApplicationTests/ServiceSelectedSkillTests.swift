import BridgeMCP
import Foundation
import XCTest

@testable import BridgeServiceApplication

final class ServiceSelectedSkillTests: XCTestCase {
  func testNativeAgentsReceiveSkillDocumentAndReferenceSnapshot() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let directory = URL(fileURLWithPath: fixture.project.root.canonicalPath)
      .appendingPathComponent("skills/review")
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("references"), withIntermediateDirectories: true)
    try Data("---\nname: review\ndescription: Review\n---\nRead references/check.md".utf8)
      .write(to: directory.appendingPathComponent("SKILL.md"))
    try Data("Check the project.".utf8)
      .write(to: directory.appendingPathComponent("references/check.md"))
    let application = makeServiceApplication(
      fixture: fixture, catalogScript: serviceModelCatalogScript)
    for provider in ["pi", "qoder"] {
      let skills = try await application.selectedSkillSnapshots(
        for: MCPServiceTaskSubmission(
          projectID: fixture.project.id.rawValue, prompt: "Review.", skillNames: ["review"],
          providerID: provider),
        project: fixture.project, deadline: .now.advanced(by: .seconds(10)))
      XCTAssertEqual(skills.map(\.name), ["review"])
      XCTAssertEqual(skills.first?.files.map(\.relativePath), ["SKILL.md", "references/check.md"])
      XCTAssertEqual(skills.first?.files.last?.content, "Check the project.")
    }
  }
}
