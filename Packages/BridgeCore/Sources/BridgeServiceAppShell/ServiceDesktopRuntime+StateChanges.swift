import BridgeServiceAppCore
import Foundation

extension BridgeServiceAppModel {
  func observeServiceChanges(_ client: any BridgeServiceClientProtocol) async {
    stateChangesTask?.cancel()
    let changes = await client.serviceChanges()
    stateChangesTask = Task { [weak self] in
      for await _ in changes {
        guard !Task.isCancelled, let self, !self.stopped else { return }
        await self.refresh(silent: true, includeCatalog: false)
      }
    }
  }
}
