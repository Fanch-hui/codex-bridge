import BridgeIPC
import BridgeServiceAppCore

extension BridgeServiceAppModel {
  func makeWorkbenchSettingsController() -> WorkbenchSettingsController {
    WorkbenchSettingsController(
      read: { [weak self] in
        guard let self else { throw BridgeServiceClientError.unavailable }
        return try await self.currentClient().workbenchSettings()
      },
      write: { [weak self] enabled in
        guard let self else { throw BridgeServiceClientError.unavailable }
        return try await self.currentClient().setWorkbenchEnabled(enabled)
      },
      onChange: { [weak self] in self?.objectWillChange.send() }
    )
  }
}
