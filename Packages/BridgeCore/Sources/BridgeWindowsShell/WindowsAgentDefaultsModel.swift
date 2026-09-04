#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeServiceAppCore

  @MainActor
  final class WindowsAgentDefaultsModel {
    let client: any BridgeServiceClientProtocol
    let displayBox: AuxiliaryDisplayBox<WindowsAgentDefaultsDisplay>
    let feedback: WindowsDesktopFeedbackStore

    private(set) var connectionState: WindowsWorkbenchDisplay.ConnectionState = .idle
    private(set) var providers: [IPCAgentProviderSummary] = []
    private(set) var installations: [IPCAgentInstallationSummary] = []
    var models: [IPCAgentModelSummary] = []
    var selectedProviderID: String?
    var selectedInstallationID: String?
    var selectedModelID: String?
    var selectedEffort = ""
    var selectedPermissionMode: String = "build"
    var modelCatalogs: [String: [IPCAgentModelSummary]] = [:]
    var persistedDefaults: [String: IPCAgentModelDefaultResponse] = [:]
    var providerErrors: [String: String] = [:]
    var refreshingProviderIDs: Set<String> = []
    var modelRefreshGenerations: [String: UInt64] = [:]
    var workbenchProjectID: String?
    var nativePermissionPolicy: IPCAgentNativePermissionPolicyResponse?
    var nativePermissionInstallationID: String?
    var nativePermissionLoading = false
    var nativePermissionSaving = false
    var nativePermissionError: String?
    var busy = false
    var statusText = "尚未加载 Agent 默认设置。"

    init(
      client: any BridgeServiceClientProtocol,
      feedback: WindowsDesktopFeedbackStore
    ) {
      self.client = client
      self.feedback = feedback
      displayBox = AuxiliaryDisplayBox(
        value: WindowsAgentDefaultsDisplay(
          connectionState: .idle,
          providerRows: [],
          selectedProviderIndex: nil,
          installationRows: [],
          selectedInstallationIndex: nil,
          installationDetailText: "请选择 Agent Provider 和安装记录。",
          modelRows: [],
          modelIDs: [],
          selectedModelIndex: nil,
          effortValues: [""],
          selectedEffortIndex: 0,
          permissionValues: Self.permissionValues(for: nil),
          selectedPermissionIndex: 0,
          refreshModelsEnabled: false,
          saveEnabled: false,
          statusText: statusText
        )
      )
    }

    func refresh() async {
      guard !busy else { return }
      busy = true
      statusText = "正在读取 Agent 目录…"
      publishDisplay()
      do {
        let status = try await client.status()
        workbenchProjectID = status.workbenchProjectID
        connectionState = .connected
        let catalog = try await client.agentCatalog()
        providers = catalog.providers
        installations = catalog.installations
        reconcileSelection()
      } catch {
        statusText = "Agent 默认设置读取失败：\(BridgeServiceErrorMessage.message(error))"
        busy = false
        publishDisplay()
        return
      }
      busy = false
      await refreshAllProviderModels()
      await refreshNativePermissionPolicy()
    }

    func selectProvider(at index: Int) {
      guard providers.indices.contains(index) else { return }
      selectedProviderID = providers[index].providerID
      selectedInstallationID = availableInstallation(for: selectedProviderID)?.installationID
      models = []
      selectedModelID = nil
      reconcilePermissionMode()
      statusText = "已选择 Provider：\(providers[index].displayName)"
      publishDisplay()
    }

    func selectInstallation(at index: Int) {
      guard installations.indices.contains(index) else { return }
      let installation = installations[index]
      selectedInstallationID = installation.installationID
      selectedProviderID = installation.providerID
      models = []
      selectedModelID = nil
      reconcilePermissionMode()
      statusText = "已选择安装：\(installation.displayName)"
      publishDisplay()
    }

    func refreshDisplaySnapshot() { publishDisplay() }

    func availableInstallation(for providerID: String? = nil)
      -> IPCAgentInstallationSummary?
    {
      let target = providerID ?? selectedProviderID
      if providerID == nil, let selectedInstallationID {
        return installations.first(where: {
          $0.installationID == selectedInstallationID
            && $0.isEnabled && $0.availability == "available" && $0.providerID == target
        })
      }
      return installations.first {
        $0.isEnabled && $0.availability == "available" && $0.providerID == target
      }
    }

    private func reconcileSelection() {
      if let selectedProviderID, providers.contains(where: { $0.providerID == selectedProviderID })
      {
        // Keep the user's provider selection.
      } else {
        selectedProviderID = providers.first?.providerID
      }
      if let selectedInstallationID,
        installations.contains(where: { $0.installationID == selectedInstallationID })
      {
        reconcilePermissionMode()
        return
      }
      selectedInstallationID = availableInstallation()?.installationID
      reconcilePermissionMode()
    }

    private func reconcilePermissionMode() {
      let values = Self.permissionValues(for: selectedProviderID)
      if !values.contains(selectedPermissionMode) {
        selectedPermissionMode = values[0]
      }
    }

    func publishDisplay() {
      let providerIndex = selectedProviderID.flatMap { id in
        providers.firstIndex { $0.providerID == id }
      }
      let installationIndex = selectedInstallationID.flatMap { id in
        installations.firstIndex { $0.installationID == id }
      }
      let installation = installationIndex.flatMap { installations[$0] }
      let modelIndex = selectedModelID.flatMap { id in models.firstIndex { $0.modelID == id } }
      let effortValues = availableEffortValues()
      let effortIndex = effortValues.firstIndex(of: selectedEffort)
      let permissionValues = Self.permissionValues(for: selectedProviderID)
      let permissionIndex = permissionValues.firstIndex(of: selectedPermissionMode)
      let providerName = providerIndex.map { providers[$0].displayName } ?? "—"
      let desktopProviders = providers.map(WindowsDesktopAgentPresentation.provider)
      let desktopInstallations = installations.map { installation in
        WindowsDesktopAgentPresentation.installation(
          installation,
          canToggle: !busy
            && (installation.isEnabled || installation.availability == "available"),
          canReprobe: !busy,
          canRemove: !busy
        )
      }
      let desktopModels = models.map(WindowsDesktopAgentPresentation.model)
      let detail =
        installation.map {
          [
            "Provider：\(providerName)",
            "安装：\($0.displayName)",
            "路径：\($0.executablePath)",
            "状态：\(ProjectAgentPresentation.availabilityLabel($0.availability))",
            "版本：\($0.version ?? "未知")",
          ].joined(separator: "\r\n")
        } ?? "请选择可用的 Agent 安装。"
      let value = WindowsAgentDefaultsDisplay(
        connectionState: connectionState,
        providerRows: providers.map { "\($0.displayName) · \($0.providerID)" },
        selectedProviderIndex: providerIndex,
        installationRows: installations.map {
          "\($0.displayName) · \(ProjectAgentPresentation.availabilityLabel($0.availability))"
        },
        selectedInstallationIndex: installationIndex,
        installationDetailText: detail,
        modelRows: models.map { "\($0.displayName) · \($0.modelID)" },
        modelIDs: models.map(\.modelID),
        selectedModelIndex: modelIndex,
        effortValues: effortValues,
        selectedEffortIndex: effortIndex,
        permissionValues: permissionValues,
        selectedPermissionIndex: permissionIndex,
        refreshModelsEnabled: connectionState == .connected && !busy && installation != nil,
        saveEnabled: connectionState == .connected && !busy && installation != nil
          && !refreshingProviderIDs.contains(selectedProviderID ?? ""),
        statusText: statusText,
        providerItems: desktopProviders,
        installationItems: desktopInstallations,
        selectedProviderID: selectedProviderID,
        selectedInstallationID: selectedInstallationID,
        selectedModelID: selectedModelID,
        selectedEffort: selectedEffort,
        selectedPermissionMode: selectedPermissionMode,
        defaultErrorMessage: statusText.hasPrefix("Agent 模型读取失败") ? statusText : nil,
        modelOptions: desktopModels,
        defaultItems: providerDefaultItems(),
        nativePermissionPolicy: desktopNativePermissionPolicy()
      )
      displayBox.store(value)
    }

    func availableEffortValues() -> [String] {
      DirectWorkspacePresentation.effortValues(
        catalog: models.flatMap(\.supportedReasoningEfforts),
        selected: [selectedEffort],
        includesProviderDefault: true
      )
    }
  }
#endif
