import BridgeFiles
import BridgeSecurity
import Foundation
import Logging
import MCP

public struct MCPServiceToolDeadlines: Sendable {
  public static let production = MCPServiceToolDeadlines(
    read: .seconds(15),
    // Submission resolves the model catalog before persisting the task; a cold
    // catalog fetch spawns codex app-server, so this needs read-level headroom.
    submit: .seconds(15),
    mutation: .seconds(10),
    projectChanges: .seconds(20)
  )

  public let read: ContinuousClock.Duration
  public let submit: ContinuousClock.Duration
  public let mutation: ContinuousClock.Duration
  public let projectChanges: ContinuousClock.Duration

  public init(
    read: ContinuousClock.Duration,
    submit: ContinuousClock.Duration,
    mutation: ContinuousClock.Duration,
    projectChanges: ContinuousClock.Duration = .seconds(20)
  ) {
    precondition(
      read > .zero && submit > .zero && mutation > .zero && projectChanges > .zero
    )
    self.read = read
    self.submit = submit
    self.mutation = mutation
    self.projectChanges = projectChanges
  }
}

public struct MCPServiceToolDispatcher: Sendable {
  let service: any BridgeMCPServiceAPI
  let exposureMode: MCPServiceExposureMode
  let clientID: MCPClientID
  let resultEncoder: MCPToolResultEncoder
  let admission: MCPToolAdmission
  let deadlines: MCPServiceToolDeadlines
  let clientAccess: @Sendable (MCPClientID) async -> MCPClientAccess
  let delegationEnabled: @Sendable () async -> Bool
  let logger: Logger
  let clock = ContinuousClock()

  public init(
    service: any BridgeMCPServiceAPI,
    exposureMode: MCPServiceExposureMode,
    clientID: MCPClientID = .chatGPT,
    resultEncoder: MCPToolResultEncoder = .init(),
    admission: MCPToolAdmission = .init(),
    deadlines: MCPServiceToolDeadlines = .production,
    clientAccess: @escaping @Sendable (MCPClientID) async -> MCPClientAccess = { _ in .unrestricted
    },
    delegationEnabled: @escaping @Sendable () async -> Bool = { true },
    logger: Logger = Logger(label: "CodexBridge.BridgeMCP.ServiceTools")
  ) {
    self.service = service
    self.exposureMode = exposureMode
    self.clientID = clientID
    self.resultEncoder = resultEncoder
    self.admission = admission
    self.deadlines = deadlines
    self.clientAccess = clientAccess
    self.delegationEnabled = delegationEnabled
    self.logger = logger
  }

  public func call(
    _ parameters: CallTool.Parameters,
    sessionID: String = "direct"
  ) async throws -> CallTool.Result {
    guard let contract = MCPServiceToolCatalog.contract(named: parameters.name) else {
      throw MCPError.invalidParams("Unknown tool name.")
    }
    if contract.route == .task, !(await delegationEnabled()) {
      return try resultEncoder.encode(
        MCPToolErrorOutput(
          error: .init(
            code: "capability_not_enabled", category: .policyDenied,
            message: "Agent delegation is not enabled in the current mode.", retryable: false,
            nextAction: "enable_workbench"
          )), isError: true)
    }
    guard contract.isExposed(in: exposureMode) else {
      return try resultEncoder.encode(
        MCPToolErrorOutput(
          error: .init(
            code: "client_permission_read_only", category: .policyDenied,
            message: "The local user has restricted this client to read-only tools.",
            retryable: false, nextAction: "request_full_access_from_local_user"
          )), isError: true
      )
    }
    let key = sessionID.isEmpty ? "direct" : sessionID
    guard await admission.acquire(sessionID: key) else {
      return try encodeQueryError(.busy)
    }
    defer { Task { await admission.release(sessionID: key) } }

    do {
      guard try await authorized(contract.name, arguments: parameters.arguments) else {
        return try resultEncoder.encode(
          MCPToolErrorOutput(
            error: .init(
              code: "client_permission_denied", category: .policyDenied,
              message: "This client is not authorized for this tool or project.", retryable: false,
              nextAction: "request_access_from_local_user"
            )), isError: true)
      }
      return try await callAdmitted(
        contract,
        arguments: parameters.arguments,
        sessionID: key
      )
    } catch let error as BridgeMCPQueryError {
      return try encodeQueryError(error)
    } catch let error as MCPToolResultEncodingError {
      return try encodeResultError(error)
    } catch let error as MCPError {
      if case .invalidParams(let detail) = error {
        return try encodeInvalidParameters(detail)
      }
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // Surface unknown failures as a structured tool error result instead of
      // a JSON-RPC protocol error, so remote clients never see raw exceptions.
      let correlationID = UUID().uuidString.lowercased()
      logger.error(
        "Lightweight MCP service tool request failed. name=\(parameters.name) error=\(error) type=\(String(describing: type(of: error)))",
        metadata: ["correlation_id": .string(correlationID)]
      )
      return try encodeQueryError(.internalFailure(correlationID: correlationID))
    }
  }

  private func authorized(_ name: MCPServiceToolName, arguments: [String: Value]?) async throws
    -> Bool
  {
    let access = await clientAccess(clientID)
    guard access.allowsTool(name.rawValue) else { return false }
    guard case .restricted(let projectIDs, _) = access else { return true }
    switch name {
    case .directReadCommand, .directWriteStdin, .directInterruptCommand:
      guard case .string(let sessionID)? = arguments?["session_id"] else { return false }
      let deadline = clock.now.advanced(by: deadlines.read)
      for projectID in projectIDs {
        let page = try await withToolDeadline(until: deadline) {
          try await service.serviceListDirectCommands(
            projectID: projectID, limit: 100, deadline: deadline)
        }
        if page.commands.contains(where: { $0.sessionID == sessionID }) { return true }
      }
      return false
    default:
      return access.permits(name, arguments: arguments)
    }
  }

  private func callAdmitted(
    _ contract: MCPServiceToolContract,
    arguments: [String: Value]?,
    sessionID: String
  ) async throws -> CallTool.Result {
    switch contract.route {
    case .fileTransfer:
      return try await callFileTransfer(contract.name, arguments: arguments, sessionID: sessionID)
    case .readOnly:
      return try await callReadOnly(contract.name, arguments: arguments)
    case .task:
      return try await callTask(contract.name, arguments: arguments, sessionID: sessionID)
    case .direct:
      return try await callDirect(contract.name, arguments: arguments)
    case .nativeSessionDirectory:
      return try await callNativeSessionDirectory(contract.name, arguments: arguments)
    }
  }
}
