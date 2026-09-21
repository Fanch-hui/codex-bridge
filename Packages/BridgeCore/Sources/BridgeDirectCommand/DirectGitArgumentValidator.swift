import Foundation

enum DirectGitArgumentValidator {
  static func areArgumentsSafe(_ arguments: [String]) -> Bool {
    guard let command = arguments.first else { return false }
    let denied = [
      "--git-dir", "--work-tree", "--no-index", "--output", "--ext-diff", "--textconv",
      "--exec-path", "--config-env", "-C", "-c", "-p", "--paginate", "--show-signature",
      "--remerge-diff", "--diff-merges",
    ]
    guard
      !arguments.contains(where: { argument in
        let option = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
        let deniedLongOption =
          option.hasPrefix("--") && option.count > 2
          && denied.contains(where: { $0.hasPrefix(option) })
        return denied.contains(argument) || deniedLongOption
          || argument.hasPrefix("-C") || argument.hasPrefix("-c")
          || argument.contains("%G") || argument.contains("%(signature")
      })
    else { return false }
    guard prettyFormatsAreSafe(arguments) else { return false }
    switch command {
    case "--version":
      return arguments.count == 1
    case "branch":
      if arguments == ["branch", "--show-current"] { return true }
      guard arguments.dropFirst().first == "--list" else { return false }
      return listingArgumentsAreSafe(arguments.dropFirst(2))
    case "tag":
      guard arguments.dropFirst().first == "--list" else { return false }
      return listingArgumentsAreSafe(arguments.dropFirst(2))
    default:
      return true
    }
  }

  private static func prettyFormatsAreSafe(_ arguments: [String]) -> Bool {
    let builtIns: Set<String> = [
      "oneline", "short", "medium", "full", "fuller", "reference", "email", "raw",
    ]
    return arguments.allSatisfy { argument in
      let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard let option = parts.first, option.hasPrefix("--"), option.count > 2,
        "--pretty".hasPrefix(option) || "--format".hasPrefix(option), parts.count == 2
      else { return true }
      let value = String(parts[1])
      return builtIns.contains(value) || value.hasPrefix("format:") || value.hasPrefix("tformat:")
        || value.contains("%") || value.isEmpty
    }
  }

  static func executionArguments(_ argv: [String]) -> [String] {
    guard argv.count > 1 else { return argv }
    let command = argv[1]
    let readFlags =
      ["diff", "log", "show"].contains(command)
      ? ["--no-ext-diff", "--no-textconv"] : []
    return [
      argv[0], "--no-pager", "-c", "core.fsmonitor=false",
      "-c", "log.showSignature=false", "-c", "format.pretty=medium", command,
    ]
      + readFlags + argv.dropFirst(2)
  }

  private static func listingArgumentsAreSafe(_ arguments: ArraySlice<String>) -> Bool {
    let flags: Set<String> = [
      "--list", "-l", "--all", "-a", "--remotes", "-r", "--verbose", "-v", "-vv",
      "--no-color", "--ignore-case", "-i", "--omit-empty", "--no-column", "--column",
    ]
    let values: Set<String> = [
      "--sort", "--contains", "--no-contains", "--merged", "--no-merged",
      "--points-at", "--color",
    ]
    var expectsValue = false
    var patternsOnly = false
    for argument in arguments {
      if expectsValue {
        guard !argument.hasPrefix("-") else { return false }
        expectsValue = false
        continue
      }
      if patternsOnly || !argument.hasPrefix("-") { continue }
      if argument == "--" {
        patternsOnly = true
        continue
      }
      if flags.contains(argument) { continue }
      let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard let option = parts.first, values.contains(String(option)) else { return false }
      expectsValue = parts.count == 1
    }
    return !expectsValue
  }
}
