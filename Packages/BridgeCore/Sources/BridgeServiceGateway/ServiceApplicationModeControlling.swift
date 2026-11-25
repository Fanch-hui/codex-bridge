import BridgeServiceApplication
import BridgeServiceCore

package protocol ServiceApplicationModeControlling: Sendable {
  func status() async throws -> ServiceApplicationModeStatus
  func setMode(_ mode: ServiceApplicationMode) async throws -> ServiceApplicationModeStatus
  func cancel() async throws -> ServiceApplicationModeStatus
}
