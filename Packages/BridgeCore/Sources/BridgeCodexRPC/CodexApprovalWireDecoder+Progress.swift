import Foundation

extension CodexApprovalWireDecoder {
  // Keep complete item evidence for approval checks; bound only its presentation.
  static func progressString(_ object: [String: JSONValue], key: String) throws -> String {
    try requiredString(object, key: key, maximumBytes: Int.max)
  }

  static func optionalProgressString(
    _ object: [String: JSONValue], key: String
  ) throws -> String? {
    try optionalString(object, key: key, maximumBytes: Int.max)
  }

  static func progressCommandActions(_ value: JSONValue?) throws -> [CodexCommandAction] {
    let values = try array(value, field: "commandActions")
    var actions: [CodexCommandAction] = []
    for (index, value) in values.enumerated() {
      let action = try commandAction(
        value, field: "commandActions[\(index)]", progress: true)
      if actions.count < 256 { actions.append(action) }
    }
    return actions
  }
}
