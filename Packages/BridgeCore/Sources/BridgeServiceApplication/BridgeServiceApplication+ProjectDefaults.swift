import BridgeServiceCore

extension BridgeServiceApplication {
  func defaultSubmissionProjectID(in records: [ServiceProjectRecord]) async throws -> String? {
    if let selected = try await settings.string(for: .workbenchProjectID),
      records.contains(where: { $0.id.rawValue == selected })
    {
      return selected
    }
    return Self.sortedProjects(records).first?.id.rawValue
  }
}
