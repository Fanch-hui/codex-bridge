#if os(Linux)
  import Foundation

  enum LinuxHealthPortOwner {
    static func owns(port: Int, processID: Int32) -> Bool {
      guard processID > 0,
        let descriptors = try? FileManager.default.contentsOfDirectory(
          atPath: "/proc/\(processID)/fd")
      else { return false }
      let sockets = Set(
        descriptors.compactMap { descriptor -> String? in
          guard
            let target = try? FileManager.default.destinationOfSymbolicLink(
              atPath: "/proc/\(processID)/fd/\(descriptor)"),
            target.hasPrefix("socket:["), target.hasSuffix("]")
          else { return nil }
          return String(target.dropFirst(8).dropLast())
        })
      guard !sockets.isEmpty else { return false }
      for table in ["tcp", "tcp6"] {
        guard
          let contents = try? readSocketTable(path: "/proc/\(processID)/net/\(table)")
        else { continue }
        for line in contents.split(separator: "\n").dropFirst() {
          let fields = line.split(whereSeparator: \.isWhitespace)
          guard fields.count > 9, fields[3] == "0A",
            let localPort = fields[1].split(separator: ":").last,
            Int(localPort, radix: 16) == port,
            sockets.contains(String(fields[9]))
          else { continue }
          return true
        }
      }
      return false
    }

    private static func readSocketTable(path: String) throws -> String {
      let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
      defer { try? handle.close() }
      var contents = Data()
      // procfs can return a short read before EOF; String(contentsOfFile:) stops there on Linux.
      while let bytes = try handle.read(upToCount: 64 * 1_024), !bytes.isEmpty {
        contents.append(bytes)
      }
      return String(decoding: contents, as: UTF8.self)
    }
  }
#endif
