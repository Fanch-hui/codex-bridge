import Foundation

extension OutboundContentSecurity {
  public static func redactedToolArguments(
    _ value: String,
    maximumUTF8Bytes: Int
  ) -> String {
    guard let data = value.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
      let encoded = try? JSONSerialization.data(
        withJSONObject: redactArgumentValue(object, maximumBytes: maximumUTF8Bytes),
        options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
      ),
      let result = String(data: encoded, encoding: .utf8)
    else {
      return redactedCommand(value, maximumUTF8Bytes: maximumUTF8Bytes)
    }
    guard result.utf8.count > maximumUTF8Bytes else { return result }
    return redactedCommand(result, maximumUTF8Bytes: maximumUTF8Bytes)
  }

  private static func redactArgumentValue(_ value: Any, maximumBytes: Int) -> Any {
    if let object = value as? [String: Any] {
      return object.reduce(into: [String: Any]()) { result, entry in
        result[entry.key] =
          isSensitiveArgumentKey(entry.key)
          ? "[REDACTED]" : redactArgumentValue(entry.value, maximumBytes: maximumBytes)
      }
    }
    if let array = value as? [Any] {
      return array.map { redactArgumentValue($0, maximumBytes: maximumBytes) }
    }
    if let string = value as? String {
      return redactedCommand(string, maximumUTF8Bytes: maximumBytes)
    }
    return value
  }

  private static func isSensitiveArgumentKey(_ key: String) -> Bool {
    key.range(
      of:
        #"(?i)(?:^|[_-])(?:api[_-]?key|runtime[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|secret(?:[_-]?key)?|password|passwd|authorization|cookie|token)$"#,
      options: .regularExpression
    ) != nil
  }
}
