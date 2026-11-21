import Crypto
import Foundation

public enum SkillSlugNormalizer {
  private static let maxLength = 128

  /// Converts arbitrary directory or declared names into a DSH-compatible kebab-case slug
  /// matching `/^[a-z0-9]+(?:-[a-z0-9]+)*$/`.
  public static func normalize(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let split = splitCamelCase(trimmed)
    var result = ""
    result.reserveCapacity(min(split.count, maxLength))
    var pendingDash = false

    for scalar in split.unicodeScalars {
      if scalar.isASCII {
        let value = scalar.value
        let isDigit = value >= 48 && value <= 57
        let isLower = value >= 97 && value <= 122
        let isUpper = value >= 65 && value <= 90
        if isDigit || isLower {
          if pendingDash, !result.isEmpty { result.append("-") }
          pendingDash = false
          result.append(Character(scalar))
        } else if isUpper {
          if pendingDash, !result.isEmpty { result.append("-") }
          pendingDash = false
          if let lower = UnicodeScalar(value + 32) {
            result.append(Character(lower))
          }
        } else if !result.isEmpty {
          pendingDash = true
        }
      } else if !result.isEmpty {
        pendingDash = true
      }
      if result.count >= maxLength { break }
    }

    while result.last == "-" {
      result.removeLast()
    }
    if result.isEmpty {
      let digest = SHA256.hash(data: Data(trimmed.utf8))
      let hex = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
      return "skill-\(hex)"
    }
    return String(result.prefix(maxLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }

  public static func isValidDSHSlug(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= maxLength else { return false }
    let bytes = Array(value.utf8)
    guard let first = bytes.first, let last = bytes.last,
      isLowerAlnum(first), isLowerAlnum(last)
    else { return false }
    var previousWasDash = false
    for byte in bytes {
      if byte == 45 {
        if previousWasDash { return false }
        previousWasDash = true
      } else if isLowerAlnum(byte) {
        previousWasDash = false
      } else {
        return false
      }
    }
    return true
  }

  private static func splitCamelCase(_ input: String) -> String {
    let scalars = Array(input.unicodeScalars)
    guard scalars.count > 1 else { return input }
    var output = ""
    output.reserveCapacity(input.count + 8)
    for index in scalars.indices {
      let current = scalars[index]
      if index > 0, current.isASCII, current.value >= 65 && current.value <= 90 {
        let prev = scalars[index - 1]
        let prevIsLowerOrDigit =
          prev.isASCII
          && ((prev.value >= 97 && prev.value <= 122) || (prev.value >= 48 && prev.value <= 57))
        let prevIsUpper = prev.isASCII && prev.value >= 65 && prev.value <= 90
        let nextIsLower =
          index + 1 < scalars.count
          && scalars[index + 1].isASCII
          && scalars[index + 1].value >= 97 && scalars[index + 1].value <= 122
        if prevIsLowerOrDigit || (prevIsUpper && nextIsLower) {
          output.append("-")
        }
      }
      output.unicodeScalars.append(current)
    }
    return output
  }

  private static func isLowerAlnum(_ byte: UInt8) -> Bool {
    (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 122)
  }
}
