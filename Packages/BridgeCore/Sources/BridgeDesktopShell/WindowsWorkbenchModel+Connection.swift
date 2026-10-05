#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore
  import Foundation

  extension WindowsWorkbenchModel {
    public func startServiceAndConnect() async {
      guard !isShuttingDown, !connectionRefreshInProgress else { return }
      let wasConnected = connectionState == .connected
      let result = await serviceConnectionCoordinator.connect(
        shouldContinue: { !self.isShuttingDown },
        probe: {
          await Task.detached(priority: .utility) {
            DesktopServiceLauncher.isServiceAvailable()
          }.value
        },
        launch: {
          self.connectionState = .connecting
          self.publishDisplay()
          return await Task.detached(priority: .utility) {
            DesktopServiceLauncher.ensureServiceRunning()
          }.value
        },
        handshake: {
          guard !self.isShuttingDown else { return false }
          return await self.connectAndRefresh(notifyOnConnect: !wasConnected)
        })
      guard !isShuttingDown, !Task.isCancelled else { return }
      switch result {
      case .connected, .connectionFailed, .inProgress:
        break
      case .blocked(.circuitOpen):
        fail("后台服务连续多次启动失败，已暂停自动重启。请检查安装目录或手动启动服务后再试。")
      case .blocked:
        break
      case .launchFailed(.readinessTimeout):
        fail("后台服务已启动但长时间未就绪，稍后将自动重试。")
      case .launchFailed(.exitedDuringStartup(let exitCode)):
        let detail = exitCode.map { "（退出码 \($0)）" } ?? ""
        fail("后台服务启动后立即退出\(detail)，稍后将自动重试。")
      case .launchFailed(.launchFailed(let systemError)):
        let detail = systemError.map { "（系统错误 \($0)）" } ?? ""
        fail("无法启动后台服务进程\(detail)，稍后将自动重试。")
      case .launchFailed(.ready):
        break
      }
      startTaskPolling()
    }

    /// Verifies the pipe transport with a `status()` round trip, then loads tasks.
    public func connectAndRefresh() async {
      guard !serviceConnectionCoordinator.isConnecting else { return }
      if await connectAndRefresh(notifyOnConnect: connectionState != .connected), !isShuttingDown {
        serviceConnectionCoordinator.reset()
      }
    }

    private func connectAndRefresh(notifyOnConnect: Bool) async -> Bool {
      guard !connectionRefreshInProgress else { return false }
      connectionRefreshInProgress = true
      connectionGeneration &+= 1
      let requestGeneration = connectionGeneration
      defer {
        connectionRefreshInProgress = false
        startTaskPolling()
      }
      connectionState = .connecting
      publishDisplay()
      var didHandshake = false
      do {
        let status = try await client.status()
        guard isCurrentConnection(requestGeneration) else { return false }
        didHandshake = true
        serviceStatus = status
        do {
          let refreshedProjects = try await client.projects()
          guard isCurrentConnection(requestGeneration) else { return didHandshake }
          if projects != refreshedProjects {
            projects = refreshedProjects
          }
          projectLoadError = nil
        } catch {
          guard isCurrentConnection(requestGeneration) else { return didHandshake }
          projectLoadError = "项目查询失败：\(BridgeServiceErrorMessage.message(error))"
        }
        selectedProjectID =
          projects.first(where: { $0.projectID == status.workbenchProjectID })?.projectID
          ?? selectedProjectID
          ?? projects.first?.projectID
        try await synchronizeWorkbenchProject()
        guard isCurrentConnection(requestGeneration) else { return didHandshake }
        if let mode = status.workbenchPermissionMode,
          BridgeDesktopWorkbenchPermissionMode(rawValue: mode) != nil
        {
          workbenchPermissionMode = mode
        }
        errorMessage = nil
        await refreshTasks()
        guard isCurrentConnection(requestGeneration), connectionState == .connected else {
          return didHandshake
        }
        startTaskPolling()
        scheduleDeferredConnectionWork(
          generation: requestGeneration,
          notifyOnConnect: notifyOnConnect
        )
        startServiceChangeSubscription(generation: requestGeneration)
      } catch {
        guard isCurrentConnection(requestGeneration) else { return didHandshake }
        fail(BridgeServiceErrorMessage.message(error))
      }
      startTaskPolling()
      return didHandshake
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
      if visible {
        // Returning to the foreground is an explicit user signal: give a
        // tripped crash-loop circuit one fresh set of launch attempts.
        serviceConnectionCoordinator.reset()
        userDidInteract()
      }
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

    func refreshServiceStatus() async {
      do {
        let status = try await client.status()
        guard !isShuttingDown, connectionState == .connected else { return }
        var changed = serviceStatus != status
        serviceStatus = status
        if let mode = status.workbenchPermissionMode,
          BridgeDesktopWorkbenchPermissionMode(rawValue: mode) != nil,
          workbenchPermissionMode != mode
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
