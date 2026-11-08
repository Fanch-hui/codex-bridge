import BridgeAgentCore
import Foundation

public enum BridgeDesktopAttachmentSelection {
  public enum Failure: LocalizedError {
    case invalidRequest
    case projectUnavailable
    case outsideProject
    case unsupportedImage

    public var errorDescription: String? {
      switch self {
      case .invalidRequest: "图片选择请求无效，请重试。"
      case .projectUnavailable: "请先选择已注册的项目。"
      case .outsideProject: "请选择当前项目内的图片。"
      case .unsupportedImage: "只支持 PNG、JPEG 和 WebP 图片。"
      }
    }
  }

  private struct Request: Decodable { let projectID: String }
  private struct Result: Encodable {
    let projectID: String
    let paths: [String]
  }

  public static func project(
    payloadJSON: String, selectedProjectID: String?, projectPaths: [String: String]
  ) throws -> (id: String, path: String) {
    guard let data = payloadJSON.data(using: .utf8),
      let request = try? JSONDecoder().decode(Request.self, from: data),
      let id = BridgeDesktopCommandValue.nonEmpty(request.projectID, maximumUTF8Bytes: 256)
    else { throw Failure.invalidRequest }
    guard id == selectedProjectID, let path = projectPaths[id], !path.isEmpty else {
      throw Failure.projectUnavailable
    }
    return (id, path)
  }

  public static func resultJSON(projectID: String, projectPath: String, selectedPath: String?)
    throws -> String
  {
    var paths: [String] = []
    if let selectedPath {
      guard let relative = AgentPathSemantics.relativePath(selectedPath, from: projectPath),
        !relative.isEmpty
      else { throw Failure.outsideProject }
      let ext = URL(fileURLWithPath: selectedPath).pathExtension.lowercased()
      guard ["png", "jpg", "jpeg", "webp"].contains(ext) else { throw Failure.unsupportedImage }
      #if os(Windows)
        paths = [relative.replacingOccurrences(of: "\\", with: "/")]
      #else
        paths = [relative]
      #endif
    }
    let data = try JSONEncoder().encode(Result(projectID: projectID, paths: paths))
    return String(decoding: data, as: UTF8.self)
  }
}
