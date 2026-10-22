import Foundation

/// Validates discarded values without retaining their strings or container contents.
struct ProgressJSONValueValidator: Sendable {
  private enum Phase: Sendable {
    case objectKeyOrEnd, objectKey, colon, objectValue, objectSeparator
    case arrayValueOrEnd, arrayValue, arraySeparator
  }
  private enum Token: Sendable {
    case string(key: Bool)
    case number(NumberPhase)
    case literal([UInt8], Int)
  }
  private enum NumberPhase: Sendable, Equatable {
    case sign, zero, integer, dot, fraction, exponent, exponentSign, exponentDigits
    var complete: Bool { [.zero, .integer, .fraction, .exponentDigits].contains(self) }
  }

  private var stack: [Phase] = []
  private var token: Token?
  private var string = ProgressJSONStringValidator()
  private(set) var complete = false

  mutating func append(_ byte: UInt8) throws {
    guard !complete else { throw invalid }
    if let current = token {
      switch current {
      case .string(let key):
        if try string.append(byte) {
          token = nil
          if key { stack[stack.count - 1] = .colon } else { finishValue() }
        }
        return
      case .literal(let value, let index):
        guard byte == value[index] else { throw invalid }
        if index + 1 == value.count {
          token = nil
          finishValue()
        } else {
          token = .literal(value, index + 1)
        }
        return
      case .number(let phase):
        if let next = numberPhase(phase, byte) {
          token = .number(next)
          return
        }
        guard phase.complete else { throw invalid }
        token = nil
        finishValue()
      }
    }
    if [0x20, 0x09, 0x0D, 0x0A].contains(byte) { return }
    guard !complete else { throw invalid }
    switch stack.last {
    case .objectKeyOrEnd where byte == 0x7D, .objectSeparator where byte == 0x7D,
      .arrayValueOrEnd where byte == 0x5D, .arraySeparator where byte == 0x5D:
      stack.removeLast()
      finishValue()
    case .objectKeyOrEnd, .objectKey:
      guard byte == 0x22 else { throw invalid }
      startString(key: true)
    case .colon:
      guard byte == 0x3A else { throw invalid }
      stack[stack.count - 1] = .objectValue
    case .objectSeparator:
      guard byte == 0x2C else { throw invalid }
      stack[stack.count - 1] = .objectKey
    case .arraySeparator:
      guard byte == 0x2C else { throw invalid }
      stack[stack.count - 1] = .arrayValue
    default:
      try startValue(byte)
    }
  }

  private var invalid: BoundedLineDecoderError { .oversizedFrame }

  private mutating func startValue(_ byte: UInt8) throws {
    switch byte {
    case 0x22: startString(key: false)
    case 0x7B, 0x5B:
      guard stack.count < 128 else { throw invalid }
      stack.append(byte == 0x7B ? .objectKeyOrEnd : .arrayValueOrEnd)
    case 0x74: token = .literal(Array("true".utf8), 1)
    case 0x66: token = .literal(Array("false".utf8), 1)
    case 0x6E: token = .literal(Array("null".utf8), 1)
    case 0x2D: token = .number(.sign)
    case 0x30: token = .number(.zero)
    case 0x31...0x39: token = .number(.integer)
    default: throw invalid
    }
  }

  private mutating func startString(key: Bool) {
    string = ProgressJSONStringValidator()
    token = .string(key: key)
  }

  private mutating func finishValue() {
    guard !stack.isEmpty else {
      complete = true
      return
    }
    switch stack[stack.count - 1] {
    case .objectValue: stack[stack.count - 1] = .objectSeparator
    case .arrayValueOrEnd, .arrayValue: stack[stack.count - 1] = .arraySeparator
    default: break
    }
  }

  private func numberPhase(_ phase: NumberPhase, _ byte: UInt8) -> NumberPhase? {
    let digit = (0x30...0x39).contains(byte)
    switch phase {
    case .sign: return byte == 0x30 ? .zero : (0x31...0x39).contains(byte) ? .integer : nil
    case .zero, .integer:
      if phase == .integer && digit { return .integer }
      if byte == 0x2E { return .dot }
      return [0x45, 0x65].contains(byte) ? .exponent : nil
    case .dot, .fraction:
      return digit
        ? .fraction : phase == .fraction && [0x45, 0x65].contains(byte) ? .exponent : nil
    case .exponent:
      return digit ? .exponentDigits : [0x2B, 0x2D].contains(byte) ? .exponentSign : nil
    case .exponentSign, .exponentDigits: return digit ? .exponentDigits : nil
    }
  }
}

private struct ProgressJSONStringValidator: Sendable {
  private var escaped = false
  private var hexRemaining = 0
  private var hexValue: UInt32 = 0
  private var highSurrogate = false
  private var requiresUnicodeEscape = false
  private var utf8Remaining = 0
  private var scalar: UInt32 = 0
  private var minimumScalar: UInt32 = 0

  mutating func append(_ byte: UInt8) throws -> Bool {
    if hexRemaining > 0 {
      try appendHex(byte)
      return false
    }
    if utf8Remaining > 0 {
      try appendContinuation(byte)
      return false
    }
    if escaped {
      escaped = false
      if byte == 0x75 {
        hexRemaining = 4
        hexValue = 0
        requiresUnicodeEscape = false
      } else {
        guard !requiresUnicodeEscape,
          [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(byte)
        else { throw invalid }
      }
      return false
    }
    if highSurrogate {
      guard byte == 0x5C else { throw invalid }
      escaped = true
      requiresUnicodeEscape = true
      return false
    }
    switch byte {
    case 0x22: return true
    case 0x5C: escaped = true
    case 0x00...0x1F: throw invalid
    case 0x20...0x7F: break
    case 0xC2...0xDF: startUTF8(byte & 0x1F, count: 1, minimum: 0x80)
    case 0xE0...0xEF: startUTF8(byte & 0x0F, count: 2, minimum: 0x800)
    case 0xF0...0xF4: startUTF8(byte & 0x07, count: 3, minimum: 0x1_0000)
    default: throw invalid
    }
    return false
  }

  private var invalid: BoundedLineDecoderError { .oversizedFrame }

  private mutating func appendHex(_ byte: UInt8) throws {
    let value: UInt32
    switch byte {
    case 0x30...0x39: value = UInt32(byte - 0x30)
    case 0x41...0x46: value = UInt32(byte - 0x41 + 10)
    case 0x61...0x66: value = UInt32(byte - 0x61 + 10)
    default: throw invalid
    }
    hexValue = hexValue * 16 + value
    hexRemaining -= 1
    guard hexRemaining == 0 else { return }
    if highSurrogate {
      guard (0xDC00...0xDFFF).contains(hexValue) else { throw invalid }
      highSurrogate = false
    } else if (0xD800...0xDBFF).contains(hexValue) {
      highSurrogate = true
    } else if (0xDC00...0xDFFF).contains(hexValue) {
      throw invalid
    }
  }

  private mutating func startUTF8(_ prefix: UInt8, count: Int, minimum: UInt32) {
    scalar = UInt32(prefix)
    utf8Remaining = count
    minimumScalar = minimum
  }

  private mutating func appendContinuation(_ byte: UInt8) throws {
    guard (0x80...0xBF).contains(byte) else { throw invalid }
    scalar = scalar * 64 + UInt32(byte & 0x3F)
    utf8Remaining -= 1
    if utf8Remaining == 0 {
      guard scalar >= minimumScalar, scalar <= 0x10_FFFF, !(0xD800...0xDFFF).contains(scalar)
      else { throw invalid }
    }
  }
}
