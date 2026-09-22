import BridgeDomain
import Foundation
import XCTest

final class TaskHandoffRendererTests: XCTestCase {
  private func packet(
    requirements: [TaskHandoffItem]? = nil, evidence: [TaskHandoffItem] = [],
    paths: [String] = [], complete: Bool = true, version: Int = 1
  ) -> TaskHandoffPacket {
    TaskHandoffPacket(
      projectID: "project-handoff", sourceTaskID: "source", sourceProviderID: "codex",
      sourceRevision: "revision-one", capturedAt: "2026-09-22T12:00:00Z",
      requirements: requirements ?? [item("requirement", "不得改变 Mac 原有接口", kind: "user")],
      outcomes: [item("status", "failed; test_failed", kind: "recorded-state")],
      evidence: evidence, changedFiles: paths, historyComplete: complete, schemaVersion: version)
  }

  private func item(_ id: String, _ text: String, kind: String) -> TaskHandoffItem {
    TaskHandoffItem(id: id, sourceTaskID: "source", kind: kind, text: text)
  }

  func testEveryUserRequirementSurvivesBeyondSixTurns() {
    let requirements = (0..<18).map { item("user-\($0)", "第\($0)轮不可遗漏的限制", kind: "user") }
    let result = TaskHandoffRenderer.render(
      packet(requirements: requirements), handoffID: "transfer-one")
    XCTAssertTrue(result.ready)
    for requirement in requirements { XCTAssertTrue(result.prompt.contains(requirement.text)) }
    XCTAssertTrue(result.prompt.contains("test_failed"))
  }

  func testOversizedRequirementsBlockInsteadOfTruncating() {
    let requirement = item("user", String(repeating: "必须保留。", count: 6000), kind: "user")
    let result = TaskHandoffRenderer.render(
      packet(requirements: [requirement]), handoffID: "transfer-two")
    XCTAssertFalse(result.ready)
    XCTAssertTrue(result.prompt.isEmpty)
    XCTAssertTrue(result.warnings.contains { $0.contains("未裁剪要求") })
  }

  func testLatestResultTailCannotBeDisplacedByCommandsOrPaths() {
    let final = item(
      "result:source",
      "已完成部分修改\n" + String(repeating: "过程说明", count: 5000)
        + "\nBLOCKER: 测试仍然失败", kind: "agent-claim-unverified")
    let commands = (0..<60).map {
      item("cmd-\($0)", String(repeating: "log", count: 900), kind: "command")
    }
    let result = TaskHandoffRenderer.render(
      packet(evidence: [final] + commands, paths: (0..<300).map { "Sources/File\($0).swift" }),
      handoffID: "transfer-three")
    XCTAssertTrue(result.ready)
    XCTAssertTrue(result.prompt.contains("BLOCKER: 测试仍然失败"))
    XCTAssertTrue(result.prompt.contains("test_failed"))
    XCTAssertLessThanOrEqual(result.prompt.utf8.count, TaskHandoffRenderer.maximumPromptBytes)
    XCTAssertTrue(result.warnings.contains { $0.contains("节选/省略") })
  }

  func testIncompleteHistoryAndUnknownSchemaFailClosed() {
    XCTAssertFalse(
      TaskHandoffRenderer.render(packet(complete: false), handoffID: "transfer-four").ready)
    XCTAssertFalse(TaskHandoffRenderer.render(packet(version: 2), handoffID: "transfer-five").ready)
  }

  func testUTF8GraphemesAndMarkerAreIncludedInBudget() {
    let text = String(repeating: "中文\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}e\u{301}", count: 100)
    for budget in [40, 80, 100, 257, 4096] {
      let excerpt = TaskHandoffRenderer.headAndTail(text, maximumBytes: budget)
      XCTAssertLessThanOrEqual(excerpt.utf8.count, budget)
      XCTAssertFalse(excerpt.unicodeScalars.contains { $0.value == 0xFFFD })
      XCTAssertEqual(String(data: Data(excerpt.utf8), encoding: .utf8), excerpt)
    }
  }

  func testControlCharactersAndAdditionalBudgetAreValidated() {
    XCTAssertFalse(
      TaskHandoffRenderer.render(
        packet(), handoffID: "transfer-six", additionalInstructions: "a\0b"
      ).ready)
    XCTAssertFalse(
      TaskHandoffRenderer.render(
        packet(), handoffID: "transfer-six",
        additionalInstructions: String(repeating: "中", count: 1366)
      ).ready)
    XCTAssertTrue(
      TaskHandoffRenderer.render(
        packet(), handoffID: "transfer-six",
        additionalInstructions: String(repeating: "x", count: 4096)
      ).ready)
  }

  func testKnownContextReservesCapacityAndUnknownContextIsDisclosed() {
    let small = TaskHandoffRenderer.render(
      packet(), handoffID: "transfer-seven", contextWindowTokens: 8192)
    XCTAssertFalse(small.ready)
    let known = TaskHandoffRenderer.render(
      packet(), handoffID: "transfer-eight", contextWindowTokens: 16000)
    XCTAssertTrue(known.ready)
    XCTAssertLessThanOrEqual(known.estimatedTokens, 16000 - 8192)
    let unknown = TaskHandoffRenderer.render(packet(), handoffID: "transfer-nine")
    XCTAssertTrue(unknown.warnings.contains { $0.contains("不保证总上下文容量") })
  }

  func testPacketRoundTripsWithoutReinterpretingMarkdownOrPaths() throws {
    let requirement = item(
      "quoted", "```json\n{\"path\":\"D:/工程/文件.swift\"}\n```\nCJK 中文", kind: "user")
    let original = packet(requirements: [requirement])
    let restored = try JSONDecoder().decode(
      TaskHandoffPacket.self, from: JSONEncoder().encode(original))
    XCTAssertEqual(original, restored)
    XCTAssertTrue(
      TaskHandoffRenderer.render(restored, handoffID: "transfer-ten").prompt.contains(
        requirement.text))
  }
}
