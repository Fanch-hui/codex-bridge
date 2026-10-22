import Foundation

struct ProgressJSONScanner: Sendable {
  private struct Container: Sendable {
    let path: String
    let object: Bool
    var expectsKey: Bool
    var key = ""
    var keys: Set<String> = []
  }

  private let policy: ProgressJSONPolicy
  private let maximumFrameBytes: Int
  private var stack: [Container] = []
  private var quoted = false
  private var escaped = false
  private var keyToken: Data?
  private var capture: ProgressJSONCapture?
  private var presentationByteCount = 0
  private(set) var output = Data()
  private(set) var omittedPaths: Set<String> = []
  private var duplicateKey = false

  var isComplete: Bool { capture == nil && !quoted && stack.isEmpty && !duplicateKey }
  var hasUnfinishedOmission: Bool { capture?.omitted == true }

  init(policy: ProgressJSONPolicy, maximumFrameBytes: Int) {
    self.policy = policy
    self.maximumFrameBytes = maximumFrameBytes
  }

  mutating func append(_ byte: UInt8) throws {
    if capture != nil {
      let complete = try capture!.append(byte)
      if complete { try finishCapture() }
      return
    }
    if quoted {
      try appendQuoted(byte)
      return
    }
    let path = valuePath
    if [0x22, 0x7B, 0x5B].contains(byte), !expectsKey,
      policy.isPresentationPath(path)
    {
      capture = try ProgressJSONCapture(
        path: path, first: byte, maximumBytes: min(16 * 1_024, maximumFrameBytes / 2))
      return
    }
    try emit(byte)
    switch byte {
    case 0x22:
      quoted = true
      escaped = false
      if expectsKey { keyToken = Data([byte]) }
    case 0x7B, 0x5B:
      guard stack.count < 128 else { throw BoundedLineDecoderError.oversizedFrame }
      stack.append(Container(path: path, object: byte == 0x7B, expectsKey: byte == 0x7B))
    case 0x7D, 0x5D:
      if !stack.isEmpty { stack.removeLast() }
    case 0x2C:
      if !stack.isEmpty { stack[stack.count - 1].expectsKey = stack.last?.object == true }
    case 0x3A:
      if !stack.isEmpty { stack[stack.count - 1].expectsKey = false }
    default: break
    }
  }

  private var expectsKey: Bool { stack.last?.expectsKey == true }

  private var valuePath: String {
    guard let parent = stack.last else { return "" }
    let key = parent.object ? parent.key : "*"
    return parent.path.isEmpty ? key : parent.path + "." + key
  }

  private mutating func appendQuoted(_ byte: UInt8) throws {
    try emit(byte)
    keyToken?.append(byte)
    if escaped {
      escaped = false
    } else if byte == 0x5C {
      escaped = true
    } else if byte == 0x22 {
      quoted = false
      if let token = keyToken, !stack.isEmpty {
        stack[stack.count - 1].key =
          (try? JSONDecoder().decode(String.self, from: token)) ?? ""
        let key = stack[stack.count - 1].key
        if !stack[stack.count - 1].keys.insert(key).inserted { duplicateKey = true }
      }
      keyToken = nil
    }
  }

  private mutating func finishCapture() throws {
    guard let value = capture else { return }
    capture = nil
    if value.omitted || value.bytes.count > maximumFrameBytes / 2 - presentationByteCount {
      omittedPaths.insert(value.path)
      try emit(policy.replacement(path: value.path, first: value.first))
    } else {
      try emit(value.bytes)
      presentationByteCount += value.bytes.count
    }
  }

  private mutating func emit(_ byte: UInt8) throws {
    guard output.count < maximumFrameBytes else { throw BoundedLineDecoderError.oversizedFrame }
    output.append(byte)
  }

  private mutating func emit(_ data: Data) throws {
    guard data.count <= maximumFrameBytes - output.count else {
      throw BoundedLineDecoderError.oversizedFrame
    }
    output.append(data)
  }
}

struct ProgressJSONCapture: Sendable {
  let path: String
  let first: UInt8
  let maximumBytes: Int
  private(set) var bytes: Data
  private(set) var omitted = false
  private var validator = ProgressJSONValueValidator()

  init(path: String, first: UInt8, maximumBytes: Int) throws {
    self.path = path
    self.first = first
    self.maximumBytes = max(1, maximumBytes)
    bytes = Data([first])
    try validator.append(first)
  }

  mutating func append(_ byte: UInt8) throws -> Bool {
    if !omitted {
      if bytes.count < maximumBytes {
        bytes.append(byte)
      } else {
        bytes.removeAll(keepingCapacity: false)
        omitted = true
      }
    }
    try validator.append(byte)
    return validator.complete
  }
}
