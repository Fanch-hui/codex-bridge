import BridgeSecurity
import BridgeServiceApplication
import BridgeServiceCore
import BridgeServiceHost
import BridgeTunnel
import Foundation
import XCTest

final class ServiceTunnelRecoveryTests: XCTestCase {
  func testReadinessTimeoutRecoversAfterRetryScheduleIsExhausted() async throws {
    try await assertTransientFailureRecovers(.readinessTimedOut)
  }

  func testTransientDoctorFailureRecoversAfterRetryScheduleIsExhausted() async throws {
    try await assertTransientFailureRecovers(
      .doctorFailed(exitCode: 2, diagnostics: "temporary network failure")
    )
  }

  func testDisconnectStopsOngoingTransientRecovery() async throws {
    let fixture = try makeTunnelRecoveryFixture(self)
    let factory = RecoveryTunnelFactory(
      failureCount: 100,
      failure: .readinessTimedOut
    )
    let controller = makeController(fixture: fixture, factory: factory)
    addTeardownBlock {
      await controller.shutdown()
    }

    await controller.bootstrap(
      localMCPURL: recoveryLocalMCPURL,
      localMCPHeaderSecret: recoveryLocalMCPSecret
    )
    do {
      _ = try await controller.configure(
        tunnelID: recoveryTunnelID,
        runtimeKey: recoveryRuntimeKey
      )
      XCTFail("Expected the first transient start to fail")
    } catch {
      XCTAssertEqual(error as? ServiceTunnelError, .startFailed)
    }

    try await waitUntil {
      await factory.attemptCount() >= 2
    }
    try await controller.disconnect()
    let attemptsAtDisconnect = await factory.attemptCount()

    try await Task.sleep(for: .milliseconds(120))

    let attemptsAfterDisconnect = await factory.attemptCount()
    XCTAssertEqual(attemptsAfterDisconnect, attemptsAtDisconnect)
    let status = await controller.status()
    XCTAssertEqual(status.lifecycle, .stopped)
    XCTAssertFalse(status.enabled)
    XCTAssertFalse(status.actionRequired)
  }

  func testExplicitAuthenticationFailureRequiresActionAndDoesNotRetry() async throws {
    let fixture = try makeTunnelRecoveryFixture(self)
    let factory = RecoveryTunnelFactory(
      failureCount: 100,
      failure: .invalidRuntimeKey,
      failureActionRequired: true
    )
    let controller = makeController(fixture: fixture, factory: factory)
    addTeardownBlock {
      await controller.shutdown()
    }

    await controller.bootstrap(
      localMCPURL: recoveryLocalMCPURL,
      localMCPHeaderSecret: recoveryLocalMCPSecret
    )
    do {
      _ = try await controller.configure(
        tunnelID: recoveryTunnelID,
        runtimeKey: recoveryRuntimeKey
      )
      XCTFail("Expected the authentication failure to be reported")
    } catch {
      XCTAssertEqual(error as? ServiceTunnelError, .startFailed)
    }

    let status = await controller.status()
    XCTAssertEqual(status.lifecycle, .failed)
    XCTAssertTrue(status.actionRequired)
    let attemptsBeforeWait = await factory.attemptCount()
    XCTAssertEqual(attemptsBeforeWait, 1)

    try await Task.sleep(for: .milliseconds(80))
    let attemptsAfterWait = await factory.attemptCount()
    XCTAssertEqual(attemptsAfterWait, 1)
  }

  private func assertTransientFailureRecovers(
    _ failure: TunnelManagerError
  ) async throws {
    let fixture = try makeTunnelRecoveryFixture(self)
    let factory = RecoveryTunnelFactory(
      failureCount: 5,
      failure: failure
    )
    let controller = makeController(fixture: fixture, factory: factory)
    addTeardownBlock {
      await controller.shutdown()
    }

    await controller.bootstrap(
      localMCPURL: recoveryLocalMCPURL,
      localMCPHeaderSecret: recoveryLocalMCPSecret
    )
    do {
      _ = try await controller.configure(
        tunnelID: recoveryTunnelID,
        runtimeKey: recoveryRuntimeKey
      )
      XCTFail("Expected the first transient start to fail")
    } catch {
      XCTAssertEqual(error as? ServiceTunnelError, .startFailed)
    }

    try await waitUntil(timeout: .seconds(3)) {
      let status = await controller.status()
      return status.lifecycle == .ready && status.acceptsRemoteSubmissions
    }

    let attempts = await factory.attemptCount()
    XCTAssertEqual(attempts, 6)
    let status = await controller.status()
    XCTAssertFalse(status.actionRequired)
    let runtimeStatus = await fixture.runtimeStatus.current()
    XCTAssertEqual(runtimeStatus.tunnelState, TunnelLifecycle.ready.rawValue)
  }

  private func makeController(
    fixture: TunnelRecoveryFixture,
    factory: RecoveryTunnelFactory
  ) -> ServiceTunnelController {
    ServiceTunnelController(
      settings: fixture.settings,
      runtimeStatus: fixture.runtimeStatus,
      secretStore: fixture.secrets,
      factory: factory,
      monitorInterval: .milliseconds(5),
      restartDelays: [.milliseconds(5)]
    )
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Condition did not become true before the deadline.")
  }
}

private struct TunnelRecoveryFixture {
  let root: URL
  let secrets: ServiceHostTestSecretStore
  let settings: ServiceSettings
  let runtimeStatus: ServiceRuntimeStatus
}

private func makeTunnelRecoveryFixture(
  _ testCase: XCTestCase
) throws -> TunnelRecoveryFixture {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "bridge-service-tunnel-recovery-tests-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
  let paths = try ServiceDataPaths.prepare(at: root)
  let store = try SimpleServiceStore(path: paths.databaseURL.path)
  let fixture = TunnelRecoveryFixture(
    root: root,
    secrets: ServiceHostTestSecretStore(),
    settings: ServiceSettings(store: store),
    runtimeStatus: ServiceRuntimeStatus()
  )
  testCase.addTeardownBlock {
    try? FileManager.default.removeItem(at: fixture.root)
  }
  return fixture
}
private enum RecoveryManagerOutcome: Sendable {
  case ready
  case failure(TunnelManagerError, actionRequired: Bool)
}

private actor RecoveryTunnelManager: ServiceTunnelManaging {
  private let outcome: RecoveryManagerOutcome
  private var lifecycle = TunnelLifecycle.stopped
  private var diagnosticsValue = TunnelDiagnostics(
    standardOutput: "",
    standardError: "",
    wasTruncated: false,
    actionRequired: false
  )

  init(outcome: RecoveryManagerOutcome) {
    self.outcome = outcome
  }

  func start() async throws {
    switch outcome {
    case .ready:
      lifecycle = .ready
      diagnosticsValue = TunnelDiagnostics(
        standardOutput: "ready",
        standardError: "",
        wasTruncated: false,
        actionRequired: false
      )
    case .failure(let error, let actionRequired):
      lifecycle = .failed
      diagnosticsValue = TunnelDiagnostics(
        standardOutput: "",
        standardError: actionRequired ? "authentication failed" : "temporary network failure",
        wasTruncated: false,
        actionRequired: actionRequired
      )
      throw error
    }
  }

  func stop() async {
    lifecycle = .stopped
  }

  func state() async -> TunnelLifecycle {
    lifecycle
  }

  func acceptsRemoteSubmissions() async -> Bool {
    lifecycle == .ready && !diagnosticsValue.actionRequired
  }

  func diagnostics() async -> TunnelDiagnostics {
    diagnosticsValue
  }
}

private final class RecoveryTunnelFactory: ServiceTunnelManagerBuilding,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let failure: TunnelManagerError
  private let failureActionRequired: Bool
  private var remainingFailures: Int
  private var attempts = 0

  init(
    failureCount: Int,
    failure: TunnelManagerError,
    failureActionRequired: Bool = false
  ) {
    precondition(failureCount >= 0)
    remainingFailures = failureCount
    self.failure = failure
    self.failureActionRequired = failureActionRequired
  }

  func helperAvailable() -> Bool {
    true
  }

  func make(
    tunnelID _: TunnelID,
    runtimeKeyReference _: SecretReference,
    localMCPURL _: URL,
    localMCPHeaderSecret _: String
  ) async throws -> any ServiceTunnelManaging {
    return lock.withLock {
      attempts += 1
      if remainingFailures > 0 {
        remainingFailures -= 1
        return RecoveryTunnelManager(
          outcome: .failure(failure, actionRequired: failureActionRequired)
        )
      }
      return RecoveryTunnelManager(outcome: .ready)
    }
  }

  func attemptCount() -> Int {
    lock.withLock { attempts }
  }
}
private let recoveryTunnelID = "tunnel_" + String(repeating: "r", count: 32)
private let recoveryRuntimeKey = "runtime_key_recovery_fixture"
private let recoveryLocalMCPSecret = String(repeating: "A", count: 43)
private let recoveryLocalMCPURL = URL(string: "http://127.0.0.1:43260/mcp")!
