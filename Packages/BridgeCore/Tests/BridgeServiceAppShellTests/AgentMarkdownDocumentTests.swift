import XCTest

@testable import BridgeServiceAppShell

final class AgentMarkdownDocumentTests: XCTestCase {
  func testParsesParagraphsAndPreservesSoftAndHardBreaks() {
    let document = AgentMarkdownDocument(
      "第一行\n第二行\n\n第三段  \n硬换行"
    )

    XCTAssertEqual(
      document.blocks.map(\.content),
      [
        .paragraph("第一行\n第二行"),
        .paragraph("第三段  \n硬换行"),
      ]
    )
  }

  func testParsesHeadingsListsQuotesAndFencedCode() {
    let document = AgentMarkdownDocument(
      """
      ## 标题

      - **文件**
      - 第二项

      1. 第一步
      2. 第二步

      > 引用第一行
      > 引用第二行

      ```swift
      let path = "*.swift"
      ```
      """
    )

    XCTAssertEqual(
      document.blocks.map(\.content),
      [
        .heading(level: 2, text: "标题"),
        .unorderedList(["**文件**", "第二项"]),
        .orderedList(["第一步", "第二步"]),
        .quote("引用第一行\n引用第二行"),
        .code(language: "swift", text: "let path = \"*.swift\""),
      ]
    )
  }

  func testParsesIndentedListAsFollowingListBlock() {
    let document = AgentMarkdownDocument(
      """
      - **生成文件**:
        1. [calculator.js]([REDACTED])
        2. [calculator.test.js]([REDACTED])

      ### 三、MCP 工具验证结果
      """
    )

    XCTAssertEqual(
      document.blocks.map(\.content),
      [
        .unorderedList(["**生成文件**:"]),
        .orderedList(["[calculator.js]([REDACTED])", "[calculator.test.js]([REDACTED])"]),
        .heading(level: 3, text: "三、MCP 工具验证结果"),
      ]
    )
  }

  func testParsesGitHubTableAndAlignment() {
    let document = AgentMarkdownDocument(
      """
      | Agent | 状态 | 说明 |
      | :--- | :---: | ---: |
      | Codex | 完成 | `main` |
      | DSH | 运行中 | 搜索网页 |
      """
    )

    XCTAssertEqual(
      document.blocks.map(\.content),
      [
        .table(
          headers: ["Agent", "状态", "说明"],
          rows: [["Codex", "完成", "`main`"], ["DSH", "运行中", "搜索网页"]],
          alignments: [.leading, .center, .trailing]
        )
      ]
    )

  }

  func testSafeFallbackRemovesSyntaxButKeepsCodeLiterals() {
    let fallback = AgentMarkdownFallback.safePlainTextFallback(
      from: "**失败 `*.swift` 和 #selector"
    )

    XCTAssertEqual(fallback, "失败 *.swift 和 #selector")
  }

  func testUnclosedStreamingFenceAndInlineMarkersRemainStable() {
    let document = AgentMarkdownDocument(
      "正在处理 `AGENTS.md`\n\n```bash\nrg --files"
    )

    XCTAssertEqual(
      document.blocks.map(\.content),
      [
        .paragraph("正在处理 `AGENTS.md`"),
        .code(language: "bash", text: "rg --files"),
      ]
    )
  }

  func testStreamingUpdateKeepsCompletedBlockIdentity() {
    let first = AgentMarkdownDocument("稳定段落\n\n正在输出")
    let updated = first.updating(content: "稳定段落\n\n正在输出更多")

    XCTAssertEqual(first.blocks.count, updated.blocks.count)
    XCTAssertEqual(first.blocks[0].id, updated.blocks[0].id)
    XCTAssertEqual(first.blocks[1].id, updated.blocks[1].id)
    XCTAssertEqual(updated.blocks[1].content, .paragraph("正在输出更多"))
  }

}
