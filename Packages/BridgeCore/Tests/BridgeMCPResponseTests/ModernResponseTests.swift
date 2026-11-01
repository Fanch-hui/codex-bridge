import Foundation
import MCP
import Testing

@testable import BridgeMCP

struct ModernResponseTests {
  func registry() -> MCPSessionRegistry {
    MCPSessionRegistry(
      boundPort: 8080,
      serverFactory: { _ in throw MCPError.internalError("Legacy factory not used") },
      statelessServerFactory: {
        let server = Server(
          name: "codex-bridge", version: "test",
          capabilities: .init(resources: .init(), tools: .init()))
        await MCPFileTransferResource.register(on: server)
        await server.withMethodHandler(ListTools.self) { _ in
          ListTools.Result(tools: MCPServiceToolCatalog(exposureMode: .full).definitions)
        }
        return server
      })
  }

  func request(_ method: String, uri: String? = nil) throws -> HTTPRequest {
    var params: [String: Any] = [
      "_meta": [
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": [:],
      ]
    ]
    var headers = [
      "Content-Type": "application/json",
      "Accept": "application/json, text/event-stream", "Mcp-Protocol-Version": "2026-07-28",
      "Mcp-Method": method,
    ]
    if let uri {
      params["uri"] = uri
      headers["Mcp-Name"] = uri
    }
    return HTTPRequest(
      method: "POST", headers: headers,
      body: try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0", "id": 1, "method": method, "params": params,
      ]), path: "/mcp")
  }

  @Test func actualDiscoveryToolsAndResourceResponses() async throws {
    let registry = registry()
    for method in ["server/discover", "tools/list", "resources/list", "resources/read"] {
      let response = await registry.handle(
        try request(
          method,
          uri: method == "resources/read" ? MCPFileTransferResource.uri : nil))
      let data = try #require(response.bodyData)
      let envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(envelope["error"] == nil)
      let result = try #require(envelope["result"] as? [String: Any])
      #expect(result["resultType"] as? String == "complete")
      #expect(result["ttlMs"] as? Int == 0)
      #expect(result["cacheScope"] as? String == "private")
      let meta = try #require(result["_meta"] as? [String: Any])
      #expect(meta["ttlMs"] == nil && meta["cacheScope"] == nil)
      if method == "server/discover" {
        #expect((result["supportedVersions"] as? [String])?.contains("2026-07-28") == true)
        #expect(result["capabilities"] is [String: Any])
      }
      if method == "tools/list" {
        let tools = try #require(result["tools"] as? [[String: Any]])
        #expect(!tools.isEmpty)
        let names = tools.compactMap { $0["name"] as? String }
        #expect(Set(names).count == tools.count)
        for tool in tools {
          #expect((tool["inputSchema"] as? [String: Any])?["type"] as? String == "object")
        }
      }
      if method == "resources/read" {
        let contents = try #require(result["contents"] as? [[String: Any]])
        #expect(contents.count == 1)
        #expect(contents.first?["uri"] as? String == MCPFileTransferResource.uri)
        #expect(contents.first?["mimeType"] as? String == MCPFileTransferResource.mimeType)
        #expect((contents.first?["text"] as? String)?.contains("<html") == true)
      }
    }
    let error = await registry.handle(try request("resources/read", uri: "ui://unknown"))
    let errorData = try #require(error.bodyData)
    let object = try #require(JSONSerialization.jsonObject(with: errorData) as? [String: Any])
    #expect(object["error"] != nil)
    #expect(object["result"] == nil)
  }

  @Test func cacheHintsApplyOnlyToCompleteCacheableResults() async throws {
    let registry = registry()
    for method in ["prompts/list", "resources/templates/list", "tools/call"] {
      for resultType in ["complete", "input_required"] {
        let body = try JSONSerialization.data(withJSONObject: [
          "jsonrpc": "2.0", "id": 2, "result": ["resultType": resultType],
        ])
        let response = await registry.addingModernResultFields(to: .data(body), method: method)
        let responseData = try #require(response.bodyData)
        let object = try #require(
          JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])
        let cacheable = method != "tools/call" && resultType == "complete"
        #expect((result["ttlMs"] != nil) == cacheable)
        #expect((result["cacheScope"] != nil) == cacheable)
        #expect(result["resultType"] as? String == resultType)
      }
    }
  }
  @Test func legacyResourceEncodingIsUnchanged() throws {
    let data = try JSONEncoder().encode(
      ReadResource.Result(contents: [MCPFileTransferResource.content()]))
    let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(result["contents"] != nil)
    #expect(result["ttlMs"] == nil)
    #expect(result["cacheScope"] == nil)
    #expect(result["resultType"] == nil)
  }

  @Test func explicitCachePolicyIsPreserved() async throws {
    let registry = registry()
    let body = try JSONSerialization.data(withJSONObject: [
      "jsonrpc": "2.0", "id": 3,
      "result": ["tools": [], "ttlMs": 60000, "cacheScope": "public"],
    ])
    let response = await registry.addingModernResultFields(to: .data(body), method: "tools/list")
    let responseData = try #require(response.bodyData)
    let object = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    let result = try #require(object["result"] as? [String: Any])
    #expect(result["ttlMs"] as? Int == 60000)
    #expect(result["cacheScope"] as? String == "public")
  }

}
