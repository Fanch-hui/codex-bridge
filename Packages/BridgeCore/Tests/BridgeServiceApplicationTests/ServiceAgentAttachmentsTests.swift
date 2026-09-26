import BridgeAgentCore
import BridgeMCP
import BridgeSecurity
import Foundation
import XCTest

@testable import BridgeServiceApplication

final class ServiceAgentAttachmentsTests: XCTestCase {
  func testCaptureBindsAuthorizedProjectImageAndRejectsUnknownModelSupport() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let directory = fixture.root.appending(path: "assets", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let image = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00])
    try image.write(to: directory.appending(path: "diagram.png"))
    let imageModel = try AgentModelDescriptor(
      id: "vision-model",
      displayName: "Vision",
      inputModalities: [.text, .image]
    )

    let attachments = try ServiceAgentAttachments.capture(
      relativePaths: ["assets/diagram.png"],
      project: fixture.project,
      model: imageModel
    )
    XCTAssertEqual(attachments.count, 1)
    XCTAssertEqual(attachments[0].relativePath, "assets/diagram.png")
    XCTAssertEqual(attachments[0].mimeType, "image/png")
    XCTAssertEqual(attachments[0].sha256, SecureFileRevision.digest(of: image).sha256)
    let loaded = try SecureProjectImageReader.read(attachments[0], projectRoot: fixture.root.path)
    XCTAssertEqual(loaded.data, image)

    let textModel = try AgentModelDescriptor(
      id: "text-model", displayName: "Text", inputModalities: [.text])
    XCTAssertThrowsError(
      try ServiceAgentAttachments.capture(
        relativePaths: ["assets/diagram.png"],
        project: fixture.project,
        model: textModel
      )
    ) { error in
      XCTAssertEqual(error as? BridgeMCPQueryError, .contractRejected)
    }
  }

  func testRestartRevalidatesOriginalImageDigestAndAllowsClearingIt() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let directory = fixture.root.appending(path: "assets", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let image = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00])
    let imageURL = directory.appending(path: "diagram.png")
    try image.write(to: imageURL)
    let model = try AgentModelDescriptor(
      id: "vision-model",
      displayName: "Vision",
      inputModalities: [.text, .image]
    )
    let original = try ServiceAgentAttachments.capture(
      relativePaths: ["assets/diagram.png"],
      project: fixture.project,
      model: model
    )

    XCTAssertEqual(
      try ServiceAgentAttachments.captureForRestart(
        relativePaths: ["assets/diagram.png"],
        originalAttachments: original,
        project: fixture.project,
        model: model
      ),
      original
    )
    var changedImage = image
    changedImage.append(0x01)
    try changedImage.write(to: imageURL)
    XCTAssertThrowsError(
      try ServiceAgentAttachments.captureForRestart(
        relativePaths: ["assets/diagram.png"],
        originalAttachments: original,
        project: fixture.project,
        model: model
      )
    ) { error in
      XCTAssertEqual(error as? BridgeMCPQueryError, .contractRejected)
    }
    XCTAssertEqual(
      try ServiceAgentAttachments.captureForRestart(
        relativePaths: [],
        originalAttachments: original,
        project: fixture.project,
        model: model
      ),
      []
    )
  }
}
