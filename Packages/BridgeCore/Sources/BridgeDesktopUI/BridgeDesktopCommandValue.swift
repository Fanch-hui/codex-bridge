import Foundation

public enum BridgeDesktopCommandValue {
  public static let maximumExecutablePathBytes = 16 * 1_024
  public static let maximumWorkbenchPromptBytes = 32 * 1_024
  public static let maximumPathBytes = 4_096
  public static let maximumPanelPathBytes = maximumPathBytes
  public static let maximumQoderDistributionBytes = 32

  public static func nonEmpty(
    _ rawValue: String?,
    maximumUTF8Bytes: Int? = nil
  ) -> String? {
    guard let rawValue else { return nil }
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    if let maximumUTF8Bytes, text(value, maximumUTF8Bytes: maximumUTF8Bytes) == nil {
      return nil
    }
    return value
  }

  public static func text(_ rawValue: String?, maximumUTF8Bytes: Int) -> String? {
    guard let rawValue,
      rawValue.utf8.count <= maximumUTF8Bytes,
      !rawValue.contains("\0")
    else { return nil }
    return rawValue
  }

  public static func nonBlankText(_ rawValue: String?, maximumUTF8Bytes: Int) -> String? {
    guard let value = text(rawValue, maximumUTF8Bytes: maximumUTF8Bytes),
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return value
  }

  public static func pathText(_ rawValue: String?, maximumUTF8Bytes: Int) -> String? {
    text(rawValue, maximumUTF8Bytes: maximumUTF8Bytes)
  }

  public static func arguments(
    _ values: [String],
    maximumCount: Int,
    maximumUTF8BytesPerArgument: Int
  ) -> [String]? {
    guard values.count <= maximumCount,
      values.allSatisfy({ text($0, maximumUTF8Bytes: maximumUTF8BytesPerArgument) != nil })
    else { return nil }
    return values
  }

  public static func qoderDistribution(_ rawValue: String?) -> String? {
    guard
      let value = nonEmpty(
        rawValue,
        maximumUTF8Bytes: maximumQoderDistributionBytes
      ), value == "cn" || value == "international"
    else {
      return nil
    }
    return value
  }
}
