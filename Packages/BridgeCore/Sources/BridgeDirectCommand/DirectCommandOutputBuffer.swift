import Foundation

public struct DirectCommandOutputBuffer: Codable, Equatable, Sendable {
  public let head: String
  public let tail: String
  public let byteCount: Int
  public let truncated: Bool

  public init(head: String, tail: String, byteCount: Int, truncated: Bool) {
    self.head = head
    self.tail = tail
    self.byteCount = byteCount
    self.truncated = truncated
  }
}

public struct DirectCommandOutputDelta: Equatable, Sendable {
  public let text: String
  public let redactionContext: String
  public let reachedEnd: Bool
  public let currentOffset: Int
  public let nextOffset: Int
  public let truncated: Bool

  public init(
    text: String, currentOffset: Int, nextOffset: Int, truncated: Bool,
    redactionContext: String = "", reachedEnd: Bool = true
  ) {
    self.redactionContext = redactionContext
    self.reachedEnd = reachedEnd
    self.text = text
    self.currentOffset = currentOffset
    self.nextOffset = nextOffset
    self.truncated = truncated
  }
}

public final class DirectCommandOutputCollector: @unchecked Sendable {
  public let maximumBytes: Int
  private let lock = NSLock()
  private var headStorage = Data()
  private var tailStorage = Data()
  private var totalByteCount = 0
  private var overflowed = false
  private static let maximumHeadBytes = 4 * 1_024
  private static let maximumTailBytes = 32 * 1_024

  public init(maximumBytes: Int = 1_048_576) {
    self.maximumBytes = max(1, maximumBytes)
  }

  public func append(_ data: Data) {
    guard !data.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }

    let headLimit = min(maximumBytes, Self.maximumHeadBytes)
    if headStorage.count < headLimit {
      let remaining = headLimit - headStorage.count
      headStorage.append(data.prefix(remaining))
    }

    if data.count >= maximumBytes {
      tailStorage = Data(data.suffix(maximumBytes))
    } else {
      tailStorage.append(data)
      if tailStorage.count > maximumBytes {
        tailStorage = Data(tailStorage.suffix(maximumBytes))
      }
    }

    let (nextCount, didOverflow) = totalByteCount.addingReportingOverflow(data.count)
    totalByteCount = didOverflow ? Int.max : nextCount
    overflowed = overflowed || totalByteCount > maximumBytes
  }

  public func snapshot() -> DirectCommandOutputBuffer {
    lock.lock()
    defer { lock.unlock() }
    let head = Self.displayString(headStorage)
    let tail = Self.displayString(tailStorage.suffix(min(maximumBytes, Self.maximumTailBytes)))
    return DirectCommandOutputBuffer(
      head: head,
      tail: tail,
      byteCount: min(totalByteCount, maximumBytes),
      truncated: overflowed
    )
  }

  public func delta(from offset: Int?, final: Bool = false) -> DirectCommandOutputDelta {
    lock.lock()
    defer { lock.unlock() }
    let total = min(totalByteCount, Int.max)
    let storedStart = max(0, total - tailStorage.count)
    let requested = max(0, offset ?? storedStart)
    let current = min(total, max(requested, storedStart))
    let startIndex = min(tailStorage.count, max(0, current - storedStart))
    let bytes = tailStorage.suffix(from: startIndex).prefix(16 * 1024)
    let atEnd = startIndex + bytes.count == tailStorage.count
    let pendingBytes = final && atEnd ? 0 : Self.incompleteSuffixLength(bytes)
    let readable = bytes.dropLast(pendingBytes)
    return DirectCommandOutputDelta(
      text: Self.displayString(readable),
      currentOffset: current,
      nextOffset: current + readable.count,
      truncated: overflowed || requested < storedStart,
      redactionContext: Self.displayString(tailStorage.prefix(startIndex)),
      reachedEnd: current + readable.count == total
    )
  }

  public func completeData() -> Data? {
    lock.lock()
    defer { lock.unlock() }
    guard !overflowed else { return nil }
    return tailStorage
  }

  public var isEmpty: Bool {
    lock.lock()
    defer { lock.unlock() }
    return totalByteCount == 0
  }

  private static func displayString<C: Collection>(_ bytes: C) -> String
  where C.Element == UInt8 {
    if !bytes.contains(0), let decoded = String(bytes: bytes, encoding: .utf8) { return decoded }
    var result = String()
    var index = bytes.startIndex
    while index != bytes.endIndex {
      let byte = bytes[index]
      let width = byte == 0 ? 0 : sequenceWidth(for: byte)
      if width > 0 {
        var end = index
        for _ in 0..<width {
          guard end != bytes.endIndex else {
            end = bytes.endIndex
            break
          }
          end = bytes.index(after: end)
        }
        if end != index {
          let sequence = bytes[index..<end]
          if sequence.count == width, let decoded = String(bytes: sequence, encoding: .utf8) {
            result.append(contentsOf: decoded)
            index = end
            continue
          }
        }
      }
      result += String(format: "\\x%02X", byte)
      index = bytes.index(after: index)
    }
    return result
  }

  private static func incompleteSuffixLength<C: Collection>(_ bytes: C) -> Int
  where C.Element == UInt8 {
    let suffix = Array(bytes.suffix(3))
    for start in suffix.indices.reversed() {
      let width = sequenceWidth(for: suffix[start])
      let remaining = suffix.count - start
      if width > remaining && suffix[(start + 1)...].allSatisfy({ ($0 & 0xC0) == 0x80 }) {
        return remaining
      }
      if width > 0 { break }
    }
    return 0
  }

  private static func sequenceWidth(for byte: UInt8) -> Int {
    switch byte {
    case 0x00...0x7F: return 1
    case 0xC2...0xDF: return 2
    case 0xE0...0xEF: return 3
    case 0xF0...0xF4: return 4
    default: return 0
    }
  }
}
