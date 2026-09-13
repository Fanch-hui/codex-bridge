import Foundation

public struct ServiceDirectConfiguration: Codable, Equatable, Sendable {
  public let commandMode: ServiceDirectCommandMode
  public let allowedCommands: [String]
  public let deniedCommands: [String]

  public init(
    commandMode: ServiceDirectCommandMode = .safe, allowedCommands: [String] = [],
    deniedCommands: [String] = []
  ) {
    self.commandMode = commandMode
    self.allowedCommands = allowedCommands
    self.deniedCommands = deniedCommands
  }

  public func applying(to project: ServiceProjectRecord) throws -> ServiceProjectRecord {
    let commands = try allowedCommands.map { line in
      let argv = try DirectCommandLine.parse(line)
      return try ServiceWorkspaceCommand(
        id: ServiceWorkspaceCommand.stableID(
          name: String(line.prefix(60)), executable: argv[0], arguments: Array(argv.dropFirst()),
          workingDirectory: nil),
        name: String(line.prefix(60)), executable: argv[0],
        arguments: Array(argv.dropFirst()))
    }
    let blacklist = try deniedCommands.enumerated().map { index, line in
      let argv = try DirectCommandLine.parse(line)
      return try ServiceCommandBlacklistRule(
        id: "global_deny_\(index)", executable: argv[0], arguments: Array(argv.dropFirst()))
    }
    return try project.updatingWorkspaceConfiguration(
      directCommandMode: commandMode, workspaceCommands: commands, commandBlacklist: blacklist,
      at: project.updatedAt)
  }

  public func validate() throws {
    guard allowedCommands.count <= 128, deniedCommands.count <= 128 else {
      throw ServiceStoreError.invalidArgument("direct.commands")
    }
    for line in allowedCommands + deniedCommands { _ = try DirectCommandLine.parse(line) }
  }
}

public enum DirectCommandLine {
  public static func parse(_ line: String) throws -> [String] {
    guard !line.isEmpty, line.utf8.count <= 4096 else { throw invalid() }
    var words: [String] = []
    var word = ""
    var quote: Character?
    var started = false
    var index = line.startIndex
    while index < line.endIndex {
      let character = line[index]
      let next = line.index(after: index)
      guard character != "\n", character != "\r", character != "\0" else { throw invalid() }
      if character == "\\", next < line.endIndex,
        "\"' ".contains(line[next]), quote != "'"
      {
        word.append(line[next])
        started = true
        index = line.index(after: next)
        continue
      }
      if let activeQuote = quote {
        if character == activeQuote { quote = nil } else { word.append(character) }
      } else if character == "\"" || character == "'" {
        quote = character
        started = true
      } else if character.isWhitespace {
        if started {
          words.append(word)
          word = ""
          started = false
        }
      } else {
        guard !";&|<>`$".contains(character) else { throw invalid() }
        word.append(character)
        started = true
      }
      index = next
    }
    guard quote == nil else { throw invalid() }
    if started { words.append(word) }
    guard !words.isEmpty, words.count <= 129, words.allSatisfy({ !$0.isEmpty }) else {
      throw invalid()
    }
    return words
  }

  private static func invalid() -> ServiceStoreError {
    .invalidArgument("请输入一条完整命令；支持引号，不支持管道、重定向或多条命令。")
  }
}

extension ServiceSettings {
  public func directConfiguration() async throws -> ServiceDirectConfiguration? {
    guard let json = try await string(for: .directConfiguration) else { return nil }
    return try JSONDecoder().decode(ServiceDirectConfiguration.self, from: Data(json.utf8))
  }

  public func setDirectConfiguration(_ value: ServiceDirectConfiguration) async throws {
    try value.validate()
    let data = try JSONEncoder().encode(value)
    try await set(String(decoding: data, as: UTF8.self), for: .directConfiguration)
  }
}
