import BridgeFiles
import BridgeSecurity
import Foundation
import MCP

extension MCPServiceToolDispatcher {
  func callDirect(
    _ name: MCPServiceToolName,
    arguments: [String: Value]?
  ) async throws -> CallTool.Result {
    switch name {
    case .directWriteProjectFile:
      return try await callDirectWriteProjectFile(arguments)
    case .directEditProjectFile:
      return try await callDirectEditProjectFile(arguments)
    case .directApplyProjectPatch:
      return try await callDirectApplyProjectPatch(arguments)
    case .directManageProjectPath:
      return try await callDirectManageProjectPath(arguments)
    case .directPreviewProjectMutation:
      return try await callDirectPreviewProjectMutation(arguments)
    case .directApplyProjectMutation:
      return try await callDirectApplyProjectMutation(arguments)
    case .directUndoProjectMutation:
      return try await callDirectUndoProjectMutation(arguments)
    case .directExecCommand:
      return try await callDirectExecCommand(arguments)
    case .listDirectCommands:
      return try await callListDirectCommands(arguments)
    case .directGitCommit:
      return try await callDirectGitCommit(arguments)
    case .directReadCommand:
      return try await callDirectReadCommand(arguments)
    case .directWriteStdin:
      return try await callDirectWriteStdin(arguments)
    case .directInterruptCommand:
      return try await callDirectInterruptCommand(arguments)
    default:
      throw MCPError.invalidParams("Unknown tool name.")
    }
  }

  private func callDirectWriteProjectFile(_ arguments: [String: Value]?) async throws
    -> CallTool.Result
  {
    let request = try parseDirectWrite(arguments)
    let deadline = clock.now.advanced(by: deadlines.mutation)
    let receipt = try await withToolDeadline(until: deadline) {
      try await service.serviceDirectWriteFile(request, deadline: deadline)
    }
    return try encodeMutationReceipt(receipt)

  }

  private func callDirectEditProjectFile(_ arguments: [String: Value]?) async throws
    -> CallTool.Result
  {
    let request = try parseDirectEdit(arguments)
    let deadline = clock.now.advanced(by: deadlines.mutation)
    let receipt = try await withToolDeadline(until: deadline) {
      try await service.serviceDirectEditFile(request, deadline: deadline)
    }
    return try encodeMutationReceipt(receipt)

  }

  private func callDirectApplyProjectPatch(_ arguments: [String: Value]?) async throws
    -> CallTool.Result
  {
    let request = try parseDirectPatch(arguments)
    let deadline = clock.now.advanced(by: deadlines.mutation)
    let receipt = try await withToolDeadline(until: deadline) {
      try await service.serviceDirectApplyPatch(request, deadline: deadline)
    }
    return try encodePatchReceipt(receipt)

  }

  private func callDirectManageProjectPath(_ arguments: [String: Value]?) async throws
    -> CallTool.Result
  {
    let request = try parseDirectManagePath(arguments)
    let deadline = clock.now.advanced(by: deadlines.mutation)
    let receipt = try await withToolDeadline(until: deadline) {
      try await service.serviceDirectManagePath(request, deadline: deadline)
    }
    return try resultEncoder.encode(ServiceDirectManagePathOutput(receipt: receipt))

  }

  private func callDirectExecCommand(_ arguments: [String: Value]?) async throws -> CallTool.Result
  {
    let request = try parseDirectExec(arguments)
    let executionDuration = max(
      deadlines.mutation,
      .milliseconds(request.yieldTimeMS) + .seconds(5)
    )
    let deadline = clock.now.advanced(by: executionDuration)
    let receipt = try await withToolDeadline(until: deadline) {
      try await service.serviceDirectExecCommand(request, deadline: deadline)
    }
    return try resultEncoder.encode(ServiceDirectExecOutput(receipt: receipt))
  }

  private func callListDirectCommands(_ arguments: [String: Value]?) async throws
    -> CallTool.Result
  {
    let values = try StrictToolArguments(
      arguments,
      allowed: ["project_id", "limit"]
    )
    let projectID = try values.optionalIdentifier("project_id", maximumUTF8Bytes: 128)
    let limit = try values.limit(maximum: 100)
    let deadline = clock.now.advanced(by: deadlines.read)
    let page = try await withToolDeadline(until: deadline) {
      try await service.serviceListDirectCommands(
        projectID: projectID,
        limit: limit,
        deadline: deadline
      )
    }
    return try resultEncoder.encode(ServiceListDirectCommandsOutput(page: page))
  }

  private func callDirectGitCommit(_ arguments: [String: Value]?) async throws -> CallTool.Result {
    let request = try parseDirectGitCommit(arguments)
    let deadline = clock.now.advanced(by: deadlines.mutation)
    let receipt = try await withToolDeadline(until: deadline) {
      try await service.serviceDirectGitCommit(request, deadline: deadline)
    }
    return try resultEncoder.encode(ServiceDirectGitCommitOutput(receipt: receipt))

  }

  private func callDirectReadCommand(_ arguments: [String: Value]?) async throws -> CallTool.Result
  {
    let values = try StrictToolArguments(
      arguments,
      allowed: ["session_id", "cursor", "wait_timeout_ms"],
      required: ["session_id"]
    )
    let sessionID = try values.requiredIdentifier("session_id", maximumUTF8Bytes: 128)
    var cursor = try values.optionalString("cursor", maximumUTF8Bytes: 128)
    let waitTimeoutMS = try values.optionalNonnegativeInteger("wait_timeout_ms") ?? 0
    guard waitTimeoutMS <= 10_000 else {
      throw MCPError.invalidParams("wait_timeout_ms must not exceed 10000.")
    }
    let deadline = clock.now.advanced(by: deadlines.read)
    let initialCursor = cursor
    var output = try await withToolDeadline(until: deadline) {
      try await service.serviceDirectReadCommand(
        sessionID: sessionID,
        cursor: initialCursor,
        deadline: deadline
      )
    }
    let baselineByteCount = output.byteCount
    let waitDeadline = clock.now.advanced(by: .milliseconds(waitTimeoutMS))
    while waitTimeoutMS > 0, output.status == "running", clock.now < waitDeadline {
      try await Task.sleep(for: .milliseconds(25))
      let requestedCursor = cursor
      output = try await withToolDeadline(until: deadline) {
        try await service.serviceDirectReadCommand(
          sessionID: sessionID,
          cursor: requestedCursor,
          deadline: deadline
        )
      }
      cursor = output.nextCursor ?? requestedCursor
      if output.status != "running" || output.byteCount != baselineByteCount
        || output.output?.isEmpty == false
      {
        break
      }
    }
    if waitTimeoutMS > 0, output.status == "running", output.byteCount == baselineByteCount {
      output = output.markingReadTimeout()
    }
    return try resultEncoder.encode(ServiceDirectCommandOutput(output: output))

  }

  private func callDirectWriteStdin(_ arguments: [String: Value]?) async throws -> CallTool.Result {
    let values = try StrictToolArguments(
      arguments,
      allowed: ["session_id", "data", "close_stdin"],
      required: ["session_id"]
    )
    let sessionID = try values.requiredIdentifier("session_id", maximumUTF8Bytes: 128)
    let data = try values.optionalText("data", maximumUTF8Bytes: 64 * 1_024) ?? ""
    let closeStdin = try values.optionalBoolean("close_stdin") ?? false
    guard !data.isEmpty || closeStdin else {
      throw MCPError.invalidParams("Provide non-empty data or set close_stdin=true.")
    }
    let deadline = clock.now.advanced(by: deadlines.mutation)
    try await withToolDeadline(until: deadline) {
      try await service.serviceDirectWriteStdin(
        sessionID: sessionID,
        data: data,
        closeStdin: closeStdin,
        deadline: deadline
      )
    }
    return try resultEncoder.encode(
      ServiceDirectWriteStdinOutput(
        sessionID: sessionID,
        bytesWritten: data.utf8.count,
        stdinClosed: closeStdin
      )
    )

  }

  private func callDirectInterruptCommand(_ arguments: [String: Value]?) async throws
    -> CallTool.Result
  {
    let values = try StrictToolArguments(
      arguments,
      allowed: ["session_id"],
      required: ["session_id"]
    )
    let sessionID = try values.requiredIdentifier("session_id", maximumUTF8Bytes: 128)
    let deadline = clock.now.advanced(by: deadlines.mutation)
    let output = try await withToolDeadline(until: deadline) {
      try await service.serviceDirectInterruptCommand(sessionID: sessionID, deadline: deadline)
    }
    return try resultEncoder.encode(ServiceDirectCommandOutput(output: output))
  }

  private func encodeMutationReceipt(_ receipt: MCPDirectWriteReceipt) throws
    -> CallTool.Result
  {
    do {
      return try resultEncoder.encode(ServiceDirectMutationOutput(receipt: receipt))
    } catch is MCPToolResultEncodingError {
      return try resultEncoder.encode(
        ServiceDirectMutationOutput(receipt: receipt.compactedForTransport())
      )
    }
  }

  private func encodePatchReceipt(_ receipt: MCPDirectPatchReceipt) throws -> CallTool.Result {
    if let partialCommit = receipt.partialCommit {
      throw BridgeMCPQueryError.patchPartialCommit(partialCommit)
    }
    do {
      return try resultEncoder.encode(ServiceDirectPatchOutput(receipt: receipt))
    } catch is MCPToolResultEncodingError {
      return try resultEncoder.encode(
        ServiceDirectPatchOutput(receipt: receipt.compactedForTransport())
      )
    }
  }

}
