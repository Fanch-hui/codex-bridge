#if os(Windows)
  import BridgeIPC
  import BridgeServiceAppCore

  extension WindowsWorkbenchModel {
    public func refreshApprovals() async {
      guard connectionState == .connected else {
        approvalStatusText = "后台 Service 未连接。"
        publishDisplay()
        return
      }
      guard !approvalRefreshInProgress else { return }
      approvalRefreshInProgress = true
      publishDisplay()

      var errors: [String] = []
      do {
        let refreshed = try await client.approvals(taskID: nil)
        if approvals != refreshed { approvals = refreshed }
      } catch {
        errors.append("安全审批读取失败：\(BridgeServiceErrorMessage.message(error))")
      }
      do {
        let refreshed = try await client.pendingDirectApprovals()
        if directApprovals != refreshed { directApprovals = refreshed }
      } catch {
        errors.append("Direct 审批读取失败：\(BridgeServiceErrorMessage.message(error))")
      }

      approvalRefreshInProgress = false
      reconcileApprovalSelection()
      approvalStatusText = errors.isEmpty ? nil : errors.joined(separator: "\r\n")
      publishDisplay()
    }

    public func selectApproval(at index: Int) {
      let items = approvalPresentationItems()
      guard items.indices.contains(index) else { return }
      let nextID = items[index].id
      guard selectedApprovalID != nextID else {
        publishDisplay()
        return
      }
      selectedApprovalID = nextID
      approvalSelectionGeneration &+= 1
      approvalStatusText = nil
      publishDisplay()
    }

    public func resolveSelectedApproval(
      decision: String,
      oneTimeToolAutoApproval: Bool = false,
      answers: [String: [String]]? = nil
    ) async {
      guard let approvalID = selectedApprovalID else {
        setApprovalStatus("请先选择要处理的审批。")
        return
      }
      await resolveApproval(
        approvalID,
        decision: decision,
        oneTimeToolAutoApproval: oneTimeToolAutoApproval,
        answers: answers
      )
    }

    func resolveApproval(
      _ approvalID: ApprovalPresentation.Identifier,
      decision: String,
      oneTimeToolAutoApproval: Bool = false,
      answers: [String: [String]]? = nil
    ) async {
      guard connectionState == .connected else {
        setApprovalStatus("后台 Service 未连接，无法处理审批。")
        return
      }
      guard let item = approvalPresentationItems().first(where: { $0.id == approvalID })
      else {
        setApprovalStatus("请先选择要处理的审批。")
        return
      }
      guard decision == "deny" || item.allowDecisions.contains(decision) else {
        setApprovalStatus("当前审批不支持该决策。", for: approvalID)
        return
      }
      if oneTimeToolAutoApproval {
        guard case .task(let rawID) = approvalID,
          decision == "allow",
          let approval = workbenchDisplaySnapshot.approvalByID[rawID],
          approval.kind == "task_start",
          approval.oneTimeToolAutoApprovalAvailable == true
        else {
          setApprovalStatus("当前审批不支持本次 AGY 工具自动批准。", for: approvalID)
          return
        }
      }
      guard resolvingApprovalIDs.insert(approvalID).inserted else { return }
      let selectionGeneration = selectedApprovalID == approvalID ? approvalSelectionGeneration : nil
      let taskIDToReveal = approvedTaskID(for: approvalID, decision: decision)
      if selectedApprovalID == approvalID { approvalStatusText = "正在处理审批…" }
      publishDisplay()

      do {
        try await sendApprovalDecision(
          approvalID,
          decision: decision,
          oneTimeToolAutoApproval: oneTimeToolAutoApproval,
          answers: answers
        )
        removeApproval(approvalID)
        await reloadTasksAndApprovals()
        if let taskIDToReveal {
          revealApprovedTask(taskID: taskIDToReveal)
        }
        finishApprovalResolution(
          approvalID,
          selectionGeneration: selectionGeneration,
          message: "已提交：\(ApprovalPresentation.decisionLabel(decision))。",
          succeeded: true
        )
      } catch {
        let message =
          error is WindowsApprovalError
          ? "审批已失效或已被处理，请刷新状态。"
          : "审批处理失败：\(BridgeServiceErrorMessage.message(error))"
        await reloadTasksAndApprovals()
        finishApprovalResolution(
          approvalID,
          selectionGeneration: selectionGeneration,
          message: message,
          succeeded: false
        )
      }
    }

    private func approvedTaskID(
      for approvalID: ApprovalPresentation.Identifier,
      decision: String
    ) -> String? {
      guard decision != "deny", case .task(let rawID) = approvalID else { return nil }
      return workbenchDisplaySnapshot.approvalByID[rawID]?.taskID
    }

    private func revealApprovedTask(taskID: String) {
      guard let task = workbenchDisplaySnapshot.taskByID[taskID] else { return }
      if selectedTaskID == task.taskID {
        openConversation(for: task)
        publishDisplay()
      } else {
        selectTask(id: task.taskID)
      }
    }

    private func sendApprovalDecision(
      _ approvalID: ApprovalPresentation.Identifier,
      decision: String,
      oneTimeToolAutoApproval: Bool,
      answers: [String: [String]]?
    ) async throws {
      switch approvalID {
      case .task(let rawID):
        guard let approval = workbenchDisplaySnapshot.approvalByID[rawID] else {
          throw WindowsApprovalError.noLongerAvailable
        }
        try await client.resolveApproval(
          IPCApprovalResolutionRequest(
            taskID: approval.taskID,
            approvalID: approval.approvalID,
            decision: decision,
            oneTimeToolAutoApproval: oneTimeToolAutoApproval ? true : nil,
            answers: answers
          )
        )
      case .direct(let rawID):
        guard !oneTimeToolAutoApproval else {
          throw WindowsApprovalError.noLongerAvailable
        }
        let accepted: Bool
        if decision == "allow" {
          accepted = try await client.approveDirectApproval(approvalID: rawID)
        } else {
          accepted = try await client.denyDirectApproval(approvalID: rawID)
        }
        guard accepted else { throw WindowsApprovalError.noLongerAvailable }
      }
    }

    func approvalPresentationItems() -> [ApprovalPresentation.Item] {
      workbenchDisplaySnapshot.approvalItems
    }

    private func reloadTasksAndApprovals() async {
      await loadTasks()
      guard connectionState == .connected else { return }
      await refreshApprovals()
    }

    private func reconcileApprovalSelection() {
      guard let selectedApprovalID else { return }
      guard approvalPresentationItems().contains(where: { $0.id == selectedApprovalID }) else {
        self.selectedApprovalID = nil
        approvalStatusText = nil
        return
      }
    }

    private func finishApprovalResolution(
      _ approvalID: ApprovalPresentation.Identifier,
      selectionGeneration: UInt64?,
      message: String,
      succeeded: Bool
    ) {
      resolvingApprovalIDs.remove(approvalID)
      if succeeded {
        feedback.postToast(message)
      } else {
        feedback.postAlert(message, title: "审批处理失败")
      }
      guard let selectionGeneration, approvalSelectionGeneration == selectionGeneration else {
        publishDisplay()
        return
      }
      approvalStatusText = message
      publishDisplay()
    }

    private func removeApproval(_ approvalID: ApprovalPresentation.Identifier) {
      switch approvalID {
      case .task(let rawID):
        approvals.removeAll { $0.approvalID == rawID }
      case .direct(let rawID):
        directApprovals.removeAll { $0.approvalID == rawID }
      }
    }

    private func setApprovalStatus(
      _ text: String,
      for approvalID: ApprovalPresentation.Identifier? = nil
    ) {
      guard approvalID == nil || selectedApprovalID == approvalID else { return }
      approvalStatusText = text
      feedback.postAlert(text, title: "审批处理失败")
      publishDisplay()
    }
  }

  private enum WindowsApprovalError: Error {
    case noLongerAvailable
  }
#endif
