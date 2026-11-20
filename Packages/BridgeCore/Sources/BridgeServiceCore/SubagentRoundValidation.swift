import Foundation

extension SubagentRound {
  static let maximumPromptBytes = 32 * 1_024
  static let maximumDependencies = 64
  static let maximumAttachments = 200

  /// Checks field bounds and the cross-field invariants of the phase model. Throws
  /// `ServiceStoreError.invalidArgument("subagentRound.<field>")`.
  func validate() throws {
    try validateIdentity()
    try validateOptions()
    try validatePhaseFields()
  }

  private func invalid(_ field: String) -> ServiceStoreError {
    .invalidArgument("subagentRound.\(field)")
  }

  private func validateIdentity() throws {
    for (value, field) in [
      (key.rootID, "rootID"), (key.childID, "childID"), (key.requestID, "requestID"),
      (parentSessionID, "parentSessionID"), (installationID, "installationID"),
    ] {
      try ServiceValidation.identifier(value, field: "subagentRound.\(field)", maximumBytes: 1_024)
    }
    try ServiceValidation.identifier(
      fingerprint, field: "subagentRound.fingerprint", maximumBytes: 128)
    try ServiceValidation.identifier(
      projectID.rawValue, field: "subagentRound.projectID", maximumBytes: 128)
    for (value, field, limit) in [
      (previousRequestID, "previousRequestID", 1_024), (previousTaskID, "previousTaskID", 128),
      (previousRunID, "previousRunID", 1_024), (taskID, "taskID", 128),
      (waitingReason, "waitingReason", 64),
    ] {
      guard let value else { continue }
      try ServiceValidation.identifier(value, field: "subagentRound.\(field)", maximumBytes: limit)
    }
    try ServiceValidation.date(createdAt, field: "subagentRound.createdAt")
    try ServiceValidation.date(childCreatedAt, field: "subagentRound.childCreatedAt")
    guard dependencies.count <= Self.maximumDependencies else { throw invalid("dependencies") }
    for dependency in dependencies {
      try ServiceValidation.identifier(
        dependency.childID, field: "subagentRound.dependencies", maximumBytes: 1_024)
      try ServiceValidation.identifier(
        dependency.requestID, field: "subagentRound.dependencies", maximumBytes: 1_024)
    }
  }

  private func validateOptions() throws {
    try ServiceValidation.optionalText(
      options.model, field: "subagentRound.model", maximumBytes: 256)
    try ServiceValidation.optionalText(
      options.effort, field: "subagentRound.effort", maximumBytes: 64)
    try ServiceValidation.optionalText(
      options.label, field: "subagentRound.label", maximumBytes: 4_096)
    guard options.attachmentPaths.count <= Self.maximumAttachments else {
      throw invalid("attachmentPaths")
    }
    for path in options.attachmentPaths {
      try ServiceValidation.text(path, field: "subagentRound.attachmentPaths", maximumBytes: 1_024)
    }
  }

  private func validatePhaseFields() throws {
    guard SubagentRoundPhase.storable(for: kind).contains(phase) else { throw invalid("phase") }
    if let prompt {
      try ServiceValidation.text(
        prompt, field: "subagentRound.prompt", maximumBytes: Self.maximumPromptBytes)
    }
    // A steer is never resent, so it never keeps its text.
    guard (prompt != nil) == (phase.holdsPrompt && !isSteer) else { throw invalid("prompt") }
    let hasTask = [.running, .attached, .settled].contains(phase)
    if hasTask, taskID == nil { throw invalid("taskID") }
    if [.queued, .cancelled, .failed].contains(phase), taskID != nil { throw invalid("taskID") }
    guard (waitingReason == nil) || phase == .queued else { throw invalid("waitingReason") }
    guard (dispatchError == nil) || phase == .unknown else { throw invalid("dispatchError") }
    guard (failureOrigin != nil) == (phase == .failed) else { throw invalid("failureOrigin") }
    guard failureReason == nil || phase == .failed else { throw invalid("failureReason") }
    try ServiceValidation.optionalText(
      failureReason, field: "subagentRound.failureReason", maximumBytes: 8_192)
    try ServiceValidation.optionalText(
      dispatchError, field: "subagentRound.dispatchError", maximumBytes: 2_048)
    guard !(isSteer && deliveryRequired) else { throw invalid("deliveryRequired") }
    guard !delivered || (deliveryRequired && [.settled, .failed].contains(phase)) else {
      throw invalid("delivered")
    }
  }
}
