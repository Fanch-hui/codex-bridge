import Foundation

struct DeepSeekHarnessACPArchive {
  let path: String
  let files: [String: Any]
  let contentOffset: UInt64

  init(path: String) throws {
    self.path = path
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    let prefix = try handle.read(upToCount: 16) ?? Data()
    guard prefix.count == 16 else {
      throw DeepSeekHarnessACPError.artifactInvalid("archive.header")
    }
    func word(_ offset: Int) -> UInt32 {
      prefix[offset..<offset + 4].enumerated().reduce(0) {
        $0 | UInt32($1.element) << ($1.offset * 8)
      }
    }
    let headerSize = word(4)
    let jsonSize = word(12)
    guard jsonSize > 0, jsonSize <= 16 * 1_024 * 1_024, headerSize >= jsonSize + 8,
      let data = try handle.read(upToCount: Int(jsonSize)), data.count == Int(jsonSize),
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let files = object["files"] as? [String: Any]
    else { throw DeepSeekHarnessACPError.artifactInvalid("archive.header") }
    self.files = files
    self.contentOffset = 8 + UInt64(headerSize)
  }

  func entry(_ relativePath: String) -> [String: Any]? {
    resolveEntry(relativePath, remainingLinks: 16)?.node
  }

  private func resolveEntry(_ relativePath: String, remainingLinks: Int) -> (
    node: [String: Any], path: String
  )? {
    let components = relativePath.split(separator: "/").map(String.init)
    guard remainingLinks > 0, !components.isEmpty,
      components.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") })
    else { return nil }
    var node: [String: Any] = ["files": files]
    for (index, component) in components.enumerated() {
      guard let children = node["files"] as? [String: Any],
        let next = children[component] as? [String: Any]
      else { return nil }
      node = next
      if let link = node["link"] as? String {
        let suffix = components.dropFirst(index + 1).joined(separator: "/")
        return resolveEntry(
          link + (suffix.isEmpty ? "" : "/" + suffix), remainingLinks: remainingLinks - 1)
      }
    }
    return (node, relativePath)
  }

  func data(_ relativePath: String) throws -> Data {
    guard let resolved = resolveEntry(relativePath, remainingLinks: 16),
      let size = resolved.node["size"] as? Int,
      size > 0, size <= 2 * 1_024 * 1_024
    else {
      throw DeepSeekHarnessACPError.artifactInvalid("archive.entry")
    }
    if resolved.node["unpacked"] as? Bool == true {
      return try DeepSeekHarnessACPArtifactRuntime.boundedData(
        at: path + ".unpacked/" + resolved.path, maximumBytes: 2 * 1_024 * 1_024,
        field: "archive.unpacked")
    }
    guard let offsetText = resolved.node["offset"] as? String, let offset = UInt64(offsetText),
      offset <= UInt64.max - contentOffset
    else {
      throw DeepSeekHarnessACPError.artifactInvalid("archive.offset")
    }
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    try handle.seek(toOffset: contentOffset + offset)
    guard let data = try handle.read(upToCount: size), data.count == size else {
      throw DeepSeekHarnessACPError.artifactInvalid("archive.entry")
    }
    return data
  }

  func unpackedPaths() -> [String] {
    func walk(_ nodes: [String: Any], prefix: String) -> [String] {
      nodes.sorted(by: { $0.key < $1.key }).flatMap { name, value -> [String] in
        guard name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
          let node = value as? [String: Any]
        else { return [] }
        let relative = prefix + name
        if let children = node["files"] as? [String: Any] {
          return walk(children, prefix: relative + "/")
        }
        return node["unpacked"] as? Bool == true && (node["size"] as? Int ?? 0) > 0
          ? [relative] : []
      }
    }
    return walk(files, prefix: "").filter { $0.hasPrefix("dsh/") }
  }
}
