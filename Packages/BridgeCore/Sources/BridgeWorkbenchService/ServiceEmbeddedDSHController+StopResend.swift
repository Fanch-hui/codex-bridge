import BridgeACP
import BridgeEmbeddedDSH
import BridgeServiceCore
import Foundation

/// How far one pass over a stop operation got.
enum StopProgress: Equatable {
  case settled
  /// The engine still reports the root running. `resendable` means it also reports no stop in
  /// flight; `resends` is how many requests were already resent for this operation.
  case rootRunning(resendable: Bool, resends: Int)
}

/// The engine kept reporting the root running after the last resend of a stop request.
struct WorkbenchStopUnconfirmed: Error {}

/// What a stop operation remembers in its result between passes.
struct StopState: Equatable {
  var stage: String?
  var resends = 0

  var value: ACPJSONValue {
    var object: [String: ACPJSONValue] = ["stopResends": .integer(Int64(resends))]
    if let stage { object["stopStage"] = .string(stage) }
    return .object(object)
  }
}

extension ServiceEmbeddedDSHController {
  /// Pauses before each resend of a stop request: five resends within about a minute.
  static let defaultStopResendDelays: [Duration] = [
    .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30),
  ]

  static func stopState(_ record: ServiceWorkbenchOperation) throws -> StopState {
    guard let json = record.resultJSON else { return StopState() }
    let object = try decodeObject(json)
    return StopState(
      stage: object["stopStage"]?.stringValue, resends: object["stopResends"]?.intValue ?? 0)
  }

  /// Sends the stop request again. The engine's own report decides: the root must be running and
  /// no stop in flight, so a stop that is merely slow is never doubled. The engine treats a
  /// repeated stop as the same stop, so a resend that races a late reply is harmless.
  ///
  /// The attempt is counted before it is made and the count is stored with the operation, so
  /// the bound holds across passes and service restarts. A request that succeeds moves the
  /// operation on to its final barrier; one that fails is reported and counted.
  func resendStop(operationID id: String) async throws {
    await operationAdmission.acquire(priority: true)
    defer { operationAdmission.release(priority: true) }
    guard let first = try await store.workbenchOperation(id: id), !first.phase.isTerminal,
      let sessionID = first.draft.sessionID
    else { return }
    let gate = operationGate(for: first)
    await gate.acquire()
    defer { gate.release() }
    guard let record = try await store.workbenchOperation(id: id), !record.phase.isTerminal
    else { return }
    let generation = try await store.workbenchGeneration(sessionID: sessionID)
    var state = try Self.stopState(record)
    guard generation.closed, generation.generation == record.generation,
      state.stage != "initialStopped"
    else { return }
    let nativeID = try await nativeSessionID(for: sessionID)
    let status = try await invoke(
      action: "session.stopStatus", payload: .object(["sessionId": .string(nativeID)]))
    guard status["stopped"]?.boolValue != true, status["stopping"]?.boolValue == false else {
      return
    }
    state.resends += 1
    do {
      _ = try await stopSession(["sessionId": .string(nativeID)], releasesExecution: false)
      state.stage = "initialStopped"
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      await receive(
        EmbeddedDSHEvent(type: "operations.reconciliationPending", payload: operationError(error)))
    }
    _ = try await store.transitionWorkbenchOperation(
      id: id, expectedVersion: record.version, phase: record.phase,
      resultJSON: try Self.json(state.value))
  }

  func setStopResendDelays(_ delays: [Duration]) {
    stopResendDelays = delays
  }

  func setEngineCallOverride(
    _ override: (@Sendable (String, ACPJSONValue) async throws -> ACPJSONValue)?
  ) {
    engineCallOverride = override
  }
}
