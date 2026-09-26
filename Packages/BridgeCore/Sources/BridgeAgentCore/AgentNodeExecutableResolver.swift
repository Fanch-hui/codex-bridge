import Foundation

public enum AgentNodeExecutableResolver {
  public static func resolve(
    near executablePath: String,
    environment: [String: String]
  ) -> String? {
    var directory = URL(fileURLWithPath: executablePath)
      .resolvingSymlinksInPath().deletingLastPathComponent()
    var directories: [String] = []
    for _ in 0..<8 {
      directories.append(directory.path)
      directories.append(directory.appendingPathComponent("bin").path)
      let parent = directory.deletingLastPathComponent()
      if parent.path == directory.path { break }
      directory = parent
    }
    return AgentExecutableResolver(
      environment: environment, additionalDirectories: directories,
      preferredExtensions: [".exe"]
    ).resolve("node")
  }
}
