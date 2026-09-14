#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore
  import Foundation

  @MainActor
  final class WindowsSettingsModel {
    let client: any BridgeServiceClientProtocol
    let displayBox: AuxiliaryDisplayBox<WindowsSettingsDisplay>
    let feedback: WindowsDesktopFeedbackStore

    var connectionState: WindowsWorkbenchDisplay.ConnectionState = .idle
    var models: [MCPModelSummary] = []
    var directConfiguration: IPCDirectConfiguration?
    var preferences: IPCModelPreferences?
    private(set) var instructions = ""
    private(set) var directMode = "require"
    private(set) var taskStartMode = "require"
    var isRefreshingModels = false
    var modelError: String?
    var keepServiceRunningAfterExit = true
    var serviceRegistered = false
    var busy = false
    var statusText = "尚未加载设置。"

    init(
      client: any BridgeServiceClientProtocol,
      feedback: WindowsDesktopFeedbackStore
    ) {
      self.client = client
      self.feedback = feedback
      keepServiceRunningAfterExit =
        UserDefaults.standard.object(forKey: "keepServiceRunningAfterAppExit") as? Bool ?? true
      serviceRegistered = WindowsServiceRegistration.isRegistered()
      displayBox = AuxiliaryDisplayBox(
        value: WindowsSettingsDisplay(
          connectionState: .idle,
          modelRows: [],
          modelIDs: [],
          selectedExecutionModelIndex: nil,
          effortValues: [],
          selectedExecutionEffortIndex: nil,
          accessValues: WindowsSettingsModel.accessValues,
          selectedAccessIndex: 0,
          fastModeEnabled: false,
          directApprovalValues: WindowsSettingsModel.approvalValues,
          selectedDirectApprovalIndex: 0,
          taskStartApprovalValues: WindowsSettingsModel.approvalValues,
          selectedTaskStartApprovalIndex: 0,
          customInstructions: "",
          savePreferencesEnabled: false,
          saveInstructionsEnabled: false,
          saveDirectApprovalEnabled: false,
          saveTaskStartApprovalEnabled: false,
          statusText: statusText,
          busy: false,
          isRefreshingModels: false,
          modelError: nil,
          keepServiceRunningAfterExit: keepServiceRunningAfterExit,
          serviceRegistered: serviceRegistered
        )
      )
    }

    nonisolated static let accessValues = ["request-approval", "auto-review", "full-access"]
    nonisolated static let approvalValues = ["require", "auto"]

    func refresh() async {
      guard !busy else { return }
      busy = true
      statusText = "正在读取设置…"
      publishDisplay()
      defer {
        busy = false
        publishDisplay()
      }
      do {
        _ = try await client.status()
        connectionState = .connected
      } catch {
        connectionState = .unavailable
        statusText = "设置读取失败：\(BridgeServiceErrorMessage.message(error))"
        publishDisplay()
        return
      }
      var failures: [String] = []
      isRefreshingModels = true
      publishDisplay()
      if await loadModelCatalog(forceRefresh: false) == nil {
        failures.append("模型：\(modelError ?? "无法读取模型目录")")
      }
      isRefreshingModels = false
      directConfiguration = try? await client.directConfiguration()
      do {
        instructions = try await client.customInstructions()
      } catch {
        failures.append("自定义指令")
      }
      do {
        directMode = try await client.directApprovalMode()
      } catch {
        failures.append("Direct 审批")
      }
      do {
        taskStartMode = try await client.taskStartApprovalMode()
      } catch {
        failures.append("任务启动审批")
      }
      statusText = failures.isEmpty ? "设置已加载。" : "部分设置读取失败：\(failures.joined(separator: "、"))"
      serviceRegistered = WindowsServiceRegistration.isRegistered()
      publishDisplay()
    }

    func savePreferences(_ value: IPCModelPreferences) async {
      guard connectionState == .connected, !busy else { return }
      guard !value.executionModel.isEmpty, !value.supervisorModel.isEmpty else {
        let message = "模型设置不完整。"
        statusText = message
        feedback.postAlert(message, title: "模型设置无法保存")
        publishDisplay()
        return
      }
      busy = true
      statusText = "正在保存模型设置…"
      publishDisplay()
      defer {
        busy = false
        publishDisplay()
      }
      let normalized = IPCModelPreferences(
        executionModel: value.executionModel,
        executionEffort: value.executionEffort,
        supervisorModel: value.supervisorModel,
        supervisorEffort: value.supervisorEffort,
        supervisorEnabled: false,
        accessMode: value.accessMode,
        fastModeEnabled: value.fastModeEnabled
      )
      do {
        try await client.setModelPreferences(normalized)
        preferences = normalized
        statusText = "模型设置已保存。"
        feedback.postToast(statusText)
      } catch {
        statusText = "模型设置保存失败：\(BridgeServiceErrorMessage.message(error))"
        feedback.postAlert(statusText)
      }
      publishDisplay()
    }

    func saveInstructions(_ value: String) async {
      guard connectionState == .connected, !busy else { return }
      guard !value.utf8.contains(0), value.utf8.count <= 32 * 1_024 else {
        let message = "自定义指令不能包含 NUL，且不能超过 32 KiB。"
        statusText = message
        feedback.postAlert(message, title: "自定义指令无法保存")
        publishDisplay()
        return
      }
      busy = true
      statusText = "正在保存自定义指令…"
      publishDisplay()
      defer {
        busy = false
        publishDisplay()
      }
      do {
        try await client.setCustomInstructions(value)
        instructions = value
        statusText = "自定义指令已保存。"
        feedback.postToast(statusText)
      } catch {
        statusText = "自定义指令保存失败：\(BridgeServiceErrorMessage.message(error))"
        feedback.postAlert(statusText)
      }
      publishDisplay()
    }

    func setDirectApprovalMode(_ mode: String) async {
      await setApprovalMode(mode, direct: true)
    }

    func setTaskStartApprovalMode(_ mode: String) async {
      await setApprovalMode(mode, direct: false)
    }

    func refreshDisplaySnapshot() { publishDisplay() }

    private func setApprovalMode(_ mode: String, direct: Bool) async {
      guard Self.approvalValues.contains(mode), connectionState == .connected, !busy else { return }
      busy = true
      statusText = "正在保存审批设置…"
      publishDisplay()
      defer {
        busy = false
        publishDisplay()
      }
      do {
        if direct {
          try await client.setDirectApprovalMode(mode)
          directMode = mode
        } else {
          try await client.setTaskStartApprovalMode(mode)
          taskStartMode = mode
        }
        statusText = "审批设置已保存。"
        feedback.postToast(statusText)
      } catch {
        statusText = "审批设置保存失败：\(BridgeServiceErrorMessage.message(error))"
        feedback.postAlert(statusText)
      }
      publishDisplay()
    }

    func publishDisplay() {
      let current = preferences
      let modelIDs = models.map(\.modelID)
      let effortValues = availableEffortValues()
      let executionIndex = current.flatMap { modelIDs.firstIndex(of: $0.executionModel) }
      let executionEffortIndex = current.flatMap {
        effortValues.firstIndex(of: $0.executionEffort)
      }
      let accessIndex = current.flatMap { Self.accessValues.firstIndex(of: $0.accessMode) }
      let directIndex = Self.approvalValues.firstIndex(of: directMode)
      let taskIndex = Self.approvalValues.firstIndex(of: taskStartMode)
      let modelOptions = models.map { model in
        BridgeDesktopModelOption(
          modelID: model.modelID,
          displayName: model.displayName,
          reasoningEfforts: model.reasoningEfforts.map {
            BridgeDesktopChoice(id: $0, title: DirectWorkspacePresentation.effortLabel($0))
          },
          defaultReasoningEffort: model.defaultReasoningEffort,
          supportsFastMode: model.supportsFastMode
        )
      }
      let value = WindowsSettingsDisplay(
        connectionState: connectionState,
        modelRows: models.map { "\($0.displayName) · \($0.modelID)" },
        modelIDs: modelIDs,
        selectedExecutionModelIndex: executionIndex,
        effortValues: effortValues,
        selectedExecutionEffortIndex: executionEffortIndex,
        accessValues: Self.accessValues,
        selectedAccessIndex: accessIndex,
        fastModeEnabled: current?.fastModeEnabled ?? false,
        directApprovalValues: Self.approvalValues,
        selectedDirectApprovalIndex: directIndex,
        taskStartApprovalValues: Self.approvalValues,
        selectedTaskStartApprovalIndex: taskIndex,
        customInstructions: instructions,
        savePreferencesEnabled: connectionState == .connected && !busy && current != nil
          && !models.isEmpty,
        saveInstructionsEnabled: connectionState == .connected && !busy,
        saveDirectApprovalEnabled: connectionState == .connected && !busy,
        saveTaskStartApprovalEnabled: connectionState == .connected && !busy,
        statusText: statusText,
        busy: busy,
        isRefreshingModels: isRefreshingModels,
        modelError: modelError,
        executionModel: current?.executionModel ?? "",
        executionEffort: current?.executionEffort ?? "",
        accessMode: current?.accessMode ?? "request-approval",
        directApprovalMode: directMode,
        taskStartApprovalMode: taskStartMode,
        modelOptions: modelOptions,
        keepServiceRunningAfterExit: keepServiceRunningAfterExit,
        serviceRegistered: serviceRegistered,
        direct: directConfiguration.map {
          BridgeDesktopDirectState(
            commandMode: $0.commandMode, allowedCommands: $0.allowedCommands,
            deniedCommands: $0.deniedCommands, usesProjectDefaults: $0.usesProjectDefaults == true,
            canSave: connectionState == .connected && !busy)
        }
      )
      displayBox.store(value)
    }

    private func availableEffortValues() -> [String] {
      let catalog =
        preferences.flatMap { value in
          models.first(where: { $0.modelID == value.executionModel })?.reasoningEfforts
        } ?? []
      return DirectWorkspacePresentation.effortValues(
        catalog: catalog,
        selected: [preferences?.executionEffort].compactMap { $0 }
      )
    }
  }
#endif
