import Foundation
import MCP

extension LocalMCPProbe {
  func makeServer() async throws -> Server {
    let snapshot = await run()
    let snapshotText = try snapshot.text()
    let snapshotName =
      "probe_status_file_\(snapshot.file.state)_loopback_\(snapshot.loopback.state)"
    FileHandle.standardError.write(Data((snapshotText + "\n").utf8))
    let schema: Value = .object([
      "type": "object", "properties": .object([:]), "additionalProperties": false,
    ])
    let annotations = Tool.Annotations(
      readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    let tools = [
      Tool(
        name: "local_mcp_probe",
        description: "重新检查合成测试文件读取与本机回环 HTTP；不访问 Bridge 服务、项目或凭据。",
        inputSchema: schema, annotations: annotations),
      Tool(
        name: snapshotName,
        description: "连接时自动检查的结果，passed 为通过、failed 为失败：\(snapshotText)",
        inputSchema: schema, annotations: annotations),
    ]
    let server = Server(
      name: "codex-bridge-local-mcp-probe", version: "2",
      instructions:
        "Synthetic-file and loopback checks already ran on connection: \(snapshotText). "
        + "Call local_mcp_probe to check again. This server has no project tools or credentials.",
      capabilities: .init(tools: .init())
    )
    await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: tools) }
    await server.withMethodHandler(CallTool.self) { parameters in
      guard parameters.name == "local_mcp_probe" || parameters.name == snapshotName,
        parameters.arguments == nil || parameters.arguments?.isEmpty == true
      else { throw MCPError.invalidParams("Expected a diagnostic tool without arguments") }
      let report = parameters.name == snapshotName ? snapshot : await self.run()
      let text = try report.text()
      FileHandle.standardError.write(Data((text + "\n").utf8))
      return CallTool.Result(
        content: [.text(text: text, annotations: nil, _meta: nil)], isError: !report.passed)
    }
    return server
  }

  func serve() async throws {
    let server = try await makeServer()
    do {
      try await server.start(transport: NativeStdioTransport.make())
      await server.waitUntilCompleted()
      await server.stop()
    } catch {
      await server.stop()
      throw error
    }
  }
}
