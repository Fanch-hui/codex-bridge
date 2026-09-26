import BridgeAgentCore
import BridgeSecurity
import Foundation
import Testing

@testable import BridgePiRPC

struct PiSelectedSkillStageTests {
  @Test func stagesAllSkillFilesForOfficialPiSkillLoadingAndCleansThemUp() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("pi-selected-skill-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = try RegisteredRoot(capturing: base)
    let skill = try AgentSelectedSkill(
      name: "review-guide", source: .project,
      contentVersion: String(repeating: "a", count: 64),
      files: [
        try AgentSelectedSkillFile(
          relativePath: "SKILL.md", content: "---\nname: review-guide\n---\nReview."),
        try AgentSelectedSkillFile(
          relativePath: "references/checklist.md", content: "Check carefully."),
      ])

    let stage = try #require(
      try PiSelectedSkillStage.create(
        skills: [skill], runtimeRoot: root,
        nonce: "11111111-1111-4111-a111-111111111111"))
    let skillDirectory = try #require(stage.skillDirectories.first)
    let skillRoot = URL(fileURLWithPath: skillDirectory)
    #expect(
      try String(
        contentsOf: skillRoot.appendingPathComponent("SKILL.md"), encoding: .utf8
      ) == "---\nname: review-guide\n---\nReview.")
    #expect(
      try String(
        contentsOf: skillRoot.appendingPathComponent("references/checklist.md"), encoding: .utf8
      ) == "Check carefully.")

    stage.cleanup()
    #expect(!FileManager.default.fileExists(atPath: skillDirectory))
  }
}
