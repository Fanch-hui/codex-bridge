import BridgeACP
import BridgeEmbeddedDSH
import Foundation

extension ServiceEmbeddedDSHController {
  package func attachProviders(_ providers: any EmbeddedDSHSharedProviders) {
    precondition(runtime == nil)
    sharedProviders = providers
  }

  package func providerSession(_ payload: ACPJSONValue) async throws -> ACPJSONValue {
    guard let runtime,
      let result = try await runtime.callIfRunning(
        action: "providerSession.confirmedResponses", payload: payload)
    else { throw EmbeddedDSHRuntimeError.transportClosed }
    return result
  }

  package func communityModelsChanged() async {
    guard !isShuttingDown, let runtime else { return }
    do {
      guard try await runtime.callIfRunning(action: "provider.refresh") != nil else {
        if !isShuttingDown, self.runtime === runtime {
          pendingCommunityProviderRefresh = true
          if runtimeStarted {
            flushPendingCommunityProviderRefreshIfNeeded(for: runtime)
          }
        }
        return
      }
      if !isShuttingDown, self.runtime === runtime {
        pendingCommunityProviderRefresh = false
      }
      await receive(EmbeddedDSHEvent(type: "community.models.changed", payload: .object([:])))
    } catch is CancellationError {
      return
    } catch EmbeddedDSHRuntimeError.stopped {
      return
    } catch {
      guard !isShuttingDown, !isChangingWorkbenchEnabled, self.runtime === runtime else { return }
      await receive(
        EmbeddedDSHEvent(
          type: "models.refreshFailed",
          payload: .object([
            "message": .string("供应商目录同步失败，请刷新模型目录。")
          ])))
    }
  }

  func resetPendingCommunityProviderRefresh() {
    pendingCommunityRefreshGeneration &+= 1
    pendingCommunityRefreshTask?.cancel()
    pendingCommunityRefreshTask = nil
    pendingCommunityProviderRefresh = false
    runtimeStarted = false
  }

  func flushPendingCommunityProviderRefreshIfNeeded(for engine: EmbeddedDSHRuntime) {
    guard !isShuttingDown, runtime === engine, pendingCommunityProviderRefresh,
      pendingCommunityRefreshTask == nil
    else { return }
    pendingCommunityRefreshGeneration &+= 1
    let generation = pendingCommunityRefreshGeneration
    pendingCommunityRefreshTask = Task {
      await self.drainPendingCommunityProviderRefresh(for: engine, generation: generation)
    }
  }

  private func drainPendingCommunityProviderRefresh(
    for engine: EmbeddedDSHRuntime, generation: UInt64
  ) async {
    defer {
      if pendingCommunityRefreshGeneration == generation {
        pendingCommunityRefreshTask = nil
      }
    }
    while !isShuttingDown, runtime === engine, pendingCommunityProviderRefresh {
      pendingCommunityProviderRefresh = false
      do {
        guard try await engine.callIfRunning(action: "provider.refresh") != nil else {
          if !isShuttingDown, runtime === engine {
            pendingCommunityProviderRefresh = true
          }
          return
        }
        guard !isShuttingDown, runtime === engine else { return }
        await receive(EmbeddedDSHEvent(type: "community.models.changed", payload: .object([:])))
      } catch is CancellationError {
        return
      } catch EmbeddedDSHRuntimeError.stopped {
        return
      } catch {
        guard !isShuttingDown, !isChangingWorkbenchEnabled, runtime === engine else { return }
        await receive(
          EmbeddedDSHEvent(
            type: "models.refreshFailed",
            payload: .object([
              "message": .string("供应商目录同步失败，请刷新模型目录。")
            ])))
        return
      }
    }
  }

  package func receiveProviderEvent(_ event: EmbeddedDSHEvent) async {
    await receive(event)
    // Refresh only an existing workbench. Model activity must never start its runtime.
    if event.type == "models.changed", let runtime {
      do {
        _ = try await runtime.callIfRunning(action: "provider.refresh")
      } catch {
        await receive(
          EmbeddedDSHEvent(
            type: "models.refreshFailed",
            payload: .object([
              "message": .string("供应商目录同步失败，请刷新模型目录。")
            ])))
      }
    }
  }
}
