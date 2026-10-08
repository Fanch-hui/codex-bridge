import Foundation

/// Bounds presentation payloads while retaining the complete protocol envelope.
public struct ProgressJSONLineDecoder: Sendable {
  public enum Dialect: Sendable { case codex, acp, pi, antigravity }

  public let maximumFrameBytes: Int
  private let policy: ProgressJSONPolicy
  private var scanner: ProgressJSONScanner

  public init(dialect: Dialect, maximumFrameBytes: Int = 1_048_576) {
    self.maximumFrameBytes = max(1, maximumFrameBytes)
    policy = ProgressJSONPolicy(dialect: dialect)
    scanner = ProgressJSONScanner(
      policy: policy, maximumFrameBytes: self.maximumFrameBytes)
  }

  public mutating func append(_ data: Data) throws -> [Data] {
    var frames: [Data] = []
    do {
      for byte in data {
        if byte == 0x0A {
          if let frame = try finishFrame() { frames.append(frame) }
        } else {
          try scanner.append(byte)
        }
      }
    } catch {
      scanner = ProgressJSONScanner(policy: policy, maximumFrameBytes: maximumFrameBytes)
      throw error
    }
    return frames
  }

  public mutating func finish() throws -> [Data] {
    guard let frame = try finishFrame() else { return [] }
    return [frame]
  }

  private mutating func finishFrame() throws -> Data? {
    defer {
      scanner = ProgressJSONScanner(policy: policy, maximumFrameBytes: maximumFrameBytes)
    }
    guard !scanner.hasUnfinishedOmission else { throw BoundedLineDecoderError.oversizedFrame }
    var frame = scanner.output
    if frame.last == 0x0D { frame.removeLast() }
    guard !frame.allSatisfy({ [0x09, 0x0D, 0x20].contains($0) }) else { return nil }
    guard !scanner.omittedPaths.isEmpty else { return frame }
    guard scanner.isComplete,
      let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
      policy.allowsOmissions(object, paths: scanner.omittedPaths)
    else { throw BoundedLineDecoderError.oversizedFrame }
    return frame
  }
}
