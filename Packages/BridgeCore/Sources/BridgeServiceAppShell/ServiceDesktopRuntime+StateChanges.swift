import BridgeServiceAppCore
import Foundation

/// Minimum spacing between task-list refreshes triggered by service state changes.
let serviceChangeRefreshSpacing: Duration = .milliseconds(300)

extension BridgeServiceAppModel {
  func observeServiceChanges(_ client: any BridgeServiceClientProtocol) async {
    stateChangesTask?.cancel()
    let changes = await client.serviceChanges()
    stateChangesTask = Task { [weak self] in
      for await _ in changes {
        guard !Task.isCancelled, let self, !self.stopped else { return }
        await self.refresh(silent: true, includeCatalog: false)
        // A streaming Agent changes its task record many times per second. The conversation has
        // its own push stream, so later changes in this window fold into one list refresh and
        // the main thread stays free for the streamed output.
        try? await Task.sleep(for: serviceChangeRefreshSpacing)
      }
    }
  }
}
