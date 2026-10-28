import Foundation
import MCP

package enum MCPFileTransferResource {
  package static let uri = "ui://codex-bridge/file-transfer.html"
  package static let mimeType = "text/html;profile=mcp-app"

  package static let descriptor = Resource(
    name: "file-transfer", uri: uri, title: "Codex Bridge 文件传输",
    description: "Upload project files and download project results.", mimeType: mimeType)

  package static func content() throws -> Resource.Content {
    guard let directory = Bundle.module.resourceURL?.appendingPathComponent("FileTransfer") else {
      throw MCPError.internalError("File transfer UI is unavailable.")
    }
    func read(_ name: String) throws -> String {
      try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }
    let html = try read("index.html")
      .replacingOccurrences(of: "{{STYLE}}", with: read("transfer.css"))
      .replacingOccurrences(of: "{{CORE}}", with: read("transfer-core.js"))
      .replacingOccurrences(of: "{{VIEW}}", with: read("transfer-view.js"))
    return .text(
      html, uri: uri, mimeType: mimeType,
      _meta: Metadata(additionalFields: [
        "ui": ["prefersBorder": true, "csp": ["connectDomains": [], "resourceDomains": []]],
        "openai/widgetDescription": "选择项目文件上传或下载成果，查看传输进度。",
        "openai/widgetPrefersBorder": true,
        "openai/widgetCSP": ["connect_domains": [], "resource_domains": []],
      ]))
  }

  package static func register(on server: Server) async {
    await server.withMethodHandler(ListResources.self) { parameters in
      guard parameters.cursor == nil else {
        throw MCPError.invalidParams("Resources do not use cursors.")
      }
      return ListResources.Result(resources: [descriptor])
    }
    await server.withMethodHandler(ReadResource.self) { parameters in
      guard parameters.uri == uri else {
        throw MCPError.invalidParams("Unknown resource URI.")
      }
      return try ReadResource.Result(contents: [content()])
    }
  }
}
