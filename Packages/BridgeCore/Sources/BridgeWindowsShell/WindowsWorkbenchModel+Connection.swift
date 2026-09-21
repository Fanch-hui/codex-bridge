#if os(Windows)
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore
  import Foundation

  extension WindowsWorkbenchModel {
    /// Launches the service if needed, then verifies connectivity via
    /// `status()` and pulls the task list.
    public func startServiceAndConnect() async {
      let wasConnected = connectionState == .connected
      connectionState = .connecting
      publishDisplay()
      let launched = await Task.detached(priority: .utility) {
        WindowsServiceLauncher.ensureServiceRunning()
      }.value
      guard launched else {
        fail("未能连接后台服务：codex-bridge-service.exe 启动失败或管道未就绪。")
        startTaskPolling()
        return
      }
      await connectAndRefresh(notifyOnConnect: !wasConnected)
    }

    /// Verifies the pipe transport with a `status()` round trip, then loads tasks.
    public func connectAndRefresh() async {
      await connectAndRefresh(notifyOnConnect: connectionState != .connected)
    }

    private func connectAndRefresh(notifyOnConnect: Bool) async {
      guard !connectionRefreshInProgress else { return }
      connectionRefreshInProgress = true
      connectionGeneration &+= 1
      let requestGeneration = connectionGeneration
      defer {
        connectionRefreshInProgress = false
        startTaskPolling()
      }
      connectionState = .connecting
      publishDisplay()
      do {
        let status = try await client.status()
        guard isCurrentConnection(requestGeneration) else { return }
        serviceStatus = status
        do {
          let refreshedProjects = try await client.projects()
          guard isCurrentConnection(requestGeneration) else { return }
          if projects != refreshedProjects {
            projects = refreshedProjects
          }
          projectLoadError = nil
        } catch {
          guard isCurrentConnection(requestGeneration) else { return }
          projectLoadError = "项目查询失败：\(BridgeServiceErrorMessage.message(error))"
        }
        selectedProjectID =
          projects.first(where: { $0.projectID == status.workbenchProjectID })?.projectID
          ?? selectedProjectID
          ?? projects.first?.projectID
        try await synchronizeWorkbenchProject()
        guard isCurrentConnection(requestGeneration) else { return }
        workbenchPermissionMode =
          Self.permissionModes.contains(status.workbenchPermissionMode ?? "")
          ? status.workbenchPermissionMode!
          : workbenchPermissionMode
        errorMessage = nil
        await refreshTasks()
        guard isCurrentConnection(requestGeneration), connectionState == .connected else { return }
        startTaskPolling()
        scheduleDeferredConnectionWork(
          generation: requestGeneration,
          notifyOnConnect: notifyOnConnect
        )
        startServiceChangeSubscription(generation: requestGeneration)
      } catch {
        guard isCurrentConnection(requestGeneration) else { return }
        fail(BridgeServiceErrorMessage.message(error))
      }
      startTaskPolling()
    }

    public func refreshTasks() async {
      guard !taskRefreshInProgress else { return }
      taskRefreshInProgress = true
      defer { taskRefreshInProgress = false }
      await loadTasks()
      guard connectionState == .connected else { return }
      await refreshApprovals()
    }

    public func shutdown() async {
      stopSchedulingForApplicationExit()
      onConnected = nil
      closeConversation()
      await client.close()
    }

    func stopSchedulingForApplicationExit() {
      isShuttingDown = true
      taskPollingTask?.cancel()
      taskPollingTask = nil
      serviceChangesTask?.cancel()
      serviceChangesTask = nil
      serviceChangeRefreshTask?.cancel()
      serviceChangeRefreshTask = nil
      serviceChangeRefreshPending = false
      deferredCatalogTask?.cancel()
      deferredCatalogTask = nil
      conversationDisplayTask?.cancel()
      conversationDisplayTask = nil
      interactionRefreshTask?.cancel()
      interactionRefreshTask = nil
    }

    func resumeAfterAppUpdateCancellation() {
      guard isShuttingDown else { return }
      isShuttingDown = false
      startTaskPolling()
    }

    func startTaskPolling() {
      guard !isShuttingDown, taskPollingTask == nil else { return }
      taskPollingTask = Task { [weak self] in
        while !Task.isCancelled {
          guard let self else { return }
          do {
            try await Task.sleep(for: self.pollingInterval())
          } catch {
            return
          }
          guard !Task.isCancelled, !self.isShuttingDown else { return }
          if self.connectionState == .connected {
            await self.refreshServiceStatus()
            guard self.connectionState == .connected else { continue }
            await self.refreshTasks()
          } else {
            await self.startServiceAndConnect()
          }
        }
      }
    }

    private func pollingInterval() -> Duration {
      if tasks.contains(where: { $0.isActive }) || !approvals.isEmpty || !directApprovals.isEmpty {
        return .seconds(2)
      }
      return isWindowVisible ? .seconds(5) : .seconds(20)
    }

    func restartTaskPolling() {
      taskPollingTask?.cancel()
      taskPollingTask = nil
      startTaskPolling()
    }

    private func isCurrentConnection(_ generation: UInt64) -> Bool {
      !isShuttingDown && connectionGeneration == generation
    }

    private func startServiceChangeSubscription(generation: UInt64) {
      serviceChangesTask?.cancel()
      serviceChangesTask = Task { [weak self] in
        guard let self else { return }
        let changes = await self.client.serviceChanges()
        for await _ in changes {
          guard !Task.isCancelled else { return }
          self.enqueueServiceChangeRefresh(generation: generation)
        }
      }
    }

    private func enqueueServiceChangeRefresh(generation: UInt64) {
      guard isCurrentConnection(generation) else { return }
      serviceChangeRefreshPending = true
      guard serviceChangeRefreshTask == nil else { return }
      serviceChangeRefreshTask = Task { [weak self] in
        guard let self else { return }
        repeat {
          self.serviceChangeRefreshPending = false
          guard self.isCurrentConnection(generation) else { break }
          await self.refreshTasks()
        } while self.serviceChangeRefreshPending && !Task.isCancelled
        self.serviceChangeRefreshTask = nil
      }
    }

    private func scheduleDeferredConnectionWork(
      generation: UInt64,
      notifyOnConnect: Bool
    ) {
      deferredCatalogTask?.cancel()
      deferredCatalogTask = Task { [weak self] in
        guard let self else { return }
        await Task.yield()
        guard self.isCurrentConnection(generation) else { return }
        if notifyOnConnect {
          await self.onConnected?()
        }
        guard self.isCurrentConnection(generation) else { return }
        await self.loadDeferredCatalogs(generation: generation)
      }
    }

    private func loadDeferredCatalogs(generation: UInt64) async {
      do {
        let catalog = try await client.agentCatalog()
        guard isCurrentConnection(generation) else { return }
        if agentProviders != catalog.providers {
          agentProviders = catalog.providers
        }
        if agentInstallations != catalog.installations {
          agentInstallations = catalog.installations
        }
      } catch {
        guard isCurrentConnection(generation) else { return }
        if !agentProviders.isEmpty { agentProviders = [] }
        if !agentInstallations.isEmpty { agentInstallations = [] }
      }
      do {
        let catalog = try await client.modelCatalog()
        guard isCurrentConnection(generation) else { return }
        models = catalog.models
        modelPreferences = catalog.preferences
        modelError = nil
      } catch {
        guard isCurrentConnection(generation) else { return }
        models = []
        modelPreferences = nil
        modelError = "模型目录读取失败：\(BridgeServiceErrorMessage.message(error))"
      }
      publishDisplay()
    }

    /// Wakes the low-frequency poll after the window returns from the tray.
    public func setWindowVisible(_ visible: Bool) {
      guard isWindowVisible != visible else {
        if visible { userDidInteract() }
        return
      }
      isWindowVisible = visible
      restartTaskPolling()
      if visible { userDidInteract() }
    }

    /// Coalesces command-driven refreshes so a batch of UI commands causes one
    /// immediate task and approval round trip.
    public func userDidInteract() {
      guard !isShuttingDown, connectionState == .connected, interactionRefreshTask == nil else {
        return
      }
      restartTaskPolling()
      interactionRefreshTask = Task { [weak self] in
        guard let self else { return }
        await Task.yield()
        guard !Task.isCancelled, !self.isShuttingDown else { return }
        await self.refreshServiceStatus()
        if self.connectionState == .connected { await self.refreshTasks() }
        self.interactionRefreshTask = nil
      }
    }

    private func refreshServiceStatus() async {
      do {
        let status = try await client.status()
        guard !isShuttingDown, connectionState == .connected else { return }
        var changed = serviceStatus != status
        serviceStatus = status
        if let mode = status.workbenchPermissionMode,
          Self.permissionModes.contains(mode), workbenchPermissionMode != mode
        {
          workbenchPermissionMode = mode
          changed = true
        }
        if errorMessage != nil {
          errorMessage = nil
          changed = true
        }
        if changed { publishDisplay() }
      } catch {
        guard !Task.isCancelled, !isShuttingDown else { return }
        fail(BridgeServiceErrorMessage.message(error))
      }
    }

    func refreshDisplaySnapshot() {
      publishDisplay()
    }

    func fail(_ message: String) {
      connectionGeneration &+= 1
      serviceChangesTask?.cancel()
      serviceChangesTask = nil
      serviceChangeRefreshTask?.cancel()
      serviceChangeRefreshTask = nil
      serviceChangeRefreshPending = false
      deferredCatalogTask?.cancel()
      deferredCatalogTask = nil
      errorMessage = message
      connectionState = .unavailable
      publishDisplay()
    }
  }
#endif
