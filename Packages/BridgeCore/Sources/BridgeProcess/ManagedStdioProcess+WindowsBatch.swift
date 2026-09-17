#if os(Windows)
  import Foundation

  extension ManagedStdioProcess {
    static let windowsBatchCommandEnvironmentKey = "CODEX_BRIDGE_BATCH_COMMAND"

    static func windowsBatchCommand(_ argv: [String]) -> String {
      let arguments = argv.dropFirst().map(windowsBatchArgument)
      return (["\"\(argv[0])\""] + arguments).joined(separator: " ")
    }

    private static func windowsBatchArgument(_ argument: String) -> String {
      var result = "\""
      var backslashes = 0
      for character in argument {
        if character == "\\" {
          backslashes += 1
          continue
        }
        if character == "\"" {
          result += String(repeating: "\\", count: backslashes * 2)
          result += "\\\""
        } else {
          result += String(repeating: "\\", count: backslashes)
          result.append(character)
        }
        backslashes = 0
      }
      result += String(repeating: "\\", count: backslashes * 2)
      result.append("\"")
      // cmd.exe and the batch file's %* forwarding each consume an escape layer.
      return escapeBatchMetacharacters(escapeBatchMetacharacters(result))
    }

    private static func escapeBatchMetacharacters(_ value: String) -> String {
      let metacharacters = "()[]%!^\"`<>&|;, *?"
      return value.reduce(into: "") { result, character in
        if metacharacters.contains(character) { result.append("^") }
        result.append(character)
      }
    }
  }
#endif
