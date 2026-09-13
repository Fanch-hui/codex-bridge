import BridgeServiceAppCore
import XCTest

final class AgentMarkdownHTMLRendererTests: XCTestCase {
  func testRendersSharedBlocksAndInlineStyles() {
    let html = AgentMarkdownHTMLRenderer.render(
      """
      ## 标题

      - **加粗** *斜体* ~~删除~~ `main`

      | 名称 | 状态 |
      | :--- | :---: |
      | Codex | 完成 |
      """
    )

    XCTAssertTrue(html.contains("<h4>标题</h4>"))
    XCTAssertTrue(html.contains("<strong>加粗</strong>"))
    XCTAssertTrue(html.contains("<em>斜体</em>"))
    XCTAssertTrue(html.contains("<del>删除</del>"))
    XCTAssertTrue(html.contains("<code class=\"markdown-inline-code\">main</code>"))
    XCTAssertTrue(html.contains("<table class=\"markdown-table\">"))
    XCTAssertTrue(html.contains("markdown-align-center"))
  }

  func testEscapesMarkupAndAllowsOnlyWebLinks() {
    let html = AgentMarkdownHTMLRenderer.render(
      "<script>alert('x')</script> [安全](https://example.com/a?b=1&c=2) [危险](javascript:alert(1))"
    )

    XCTAssertTrue(html.contains("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;"))
    XCTAssertTrue(html.contains("href=\"https://example.com/a?b=1&amp;c=2\""))
    XCTAssertFalse(html.contains("href=\"javascript:"))
    XCTAssertFalse(html.contains("<script>"))
  }

  func testStreamingUsesSafePlainTextAndCursor() {
    let html = AgentMarkdownHTMLRenderer.render("## **正在输出", isFinal: false)

    XCTAssertTrue(html.hasSuffix("▍</span></p>"))
    XCTAssertTrue(html.contains("正在输出"))
    XCTAssertFalse(html.contains("##"))
    XCTAssertFalse(html.contains("**"))
  }
}
