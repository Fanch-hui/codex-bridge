#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import Foundation

  extension CodexBridgeDesktopApplication {
    static func runDesktopApprovalCommand(
      _ envelope: BridgeDesktopCommandEnvelope,
      model: WindowsWorkbenchModel
    ) -> Bool {
      let payload = envelope.payload
      switch envelope.command {
      case .resolveApproval:
        guard let approvalID = BridgeDesktopCommandValue.nonEmpty(payload.approvalID),
          let taskID = BridgeDesktopCommandValue.nonEmpty(payload.taskID),
          let decision = BridgeDesktopCommandValue.nonEmpty(payload.decision)
        else { return true }
        let oneTimeToolAutoApproval = payload.oneTimeToolAutoApproval == true
        guard !oneTimeToolAutoApproval || payload.confirmed == true else { return true }
        resolveTaskApproval(
          approvalID: approvalID,
          taskID: taskID,
          decision: decision,
          oneTimeToolAutoApproval: oneTimeToolAutoApproval,
          answersJSON: BridgeDesktopCommandValue.nonEmpty(payload.input),
          model: model
        )
      case .resolveDirectApproval:
        resolveDirectApproval(envelope, model: model)
      default:
        return false
      }
      return true
    }

    private static func resolveTaskApproval(
      approvalID: String,
      taskID: String,
      decision: String,
      oneTimeToolAutoApproval: Bool,
      answersJSON: String?,
      model: WindowsWorkbenchModel
    ) {
      let items = model.approvalPresentationItems()
      let approvals = model.approvals
      guard let index = items.firstIndex(where: { $0.id == .task(approvalID) }),
        approvals.contains(where: { $0.approvalID == approvalID && $0.taskID == taskID })
      else { return }
      let requiresAnswers = approvals.first { $0.approvalID == approvalID }?.kind == "user_input"
      let cancellingInput = requiresAnswers && decision == "cancel"
      let answers = decodeAnswers(answersJSON)
      guard cancellingInput ? answersJSON == nil : !requiresAnswers || answers != nil else {
        return
      }
      model.selectApproval(at: index)
      Task { @MainActor in
        await model.resolveApproval(
          .task(approvalID),
          decision: decision,
          oneTimeToolAutoApproval: oneTimeToolAutoApproval,
          answers: answers
        )
      }
    }

    private static func decodeAnswers(_ rawValue: String?) -> [String: [String]]? {
      guard let input = BridgeDesktopCommandValue.text(rawValue, maximumUTF8Bytes: 64 * 1_024),
        let data = input.data(using: .utf8),
        let answers = try? JSONDecoder().decode([String: [String]].self, from: data),
        !answers.isEmpty
      else { return nil }
      return answers
    }

    private static func resolveDirectApproval(
      _ envelope: BridgeDesktopCommandEnvelope,
      model: WindowsWorkbenchModel
    ) {
      guard let approvalID = BridgeDesktopCommandValue.nonEmpty(envelope.payload.approvalID),
        let decision = BridgeDesktopCommandValue.nonEmpty(envelope.payload.decision),
        let index = model.approvalPresentationItems().firstIndex(where: {
          $0.id == .direct(approvalID)
        })
      else { return }
      model.selectApproval(at: index)
      Task { @MainActor in await model.resolveApproval(.direct(approvalID), decision: decision) }
    }
  }
#endif
