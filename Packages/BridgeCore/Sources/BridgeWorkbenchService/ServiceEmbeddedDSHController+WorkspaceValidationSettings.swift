import BridgeACP
import BridgeDomain
import BridgeSecurity
import BridgeServiceCore
import Crypto
import Foundation

struct WorkbenchValidationCommand: Codable, Equatable, Sendable {
  let executable: String
  let arguments: [String]
}

struct WorkbenchValidationConfiguration: Codable, Equatable, Sendable {
  let commands: [WorkbenchValidationCommand]
  let timeoutSeconds: Int
}

extension ServiceEmbeddedDSHController {
  private static func workspaceValidationKey(_ projectID: ProjectID) -> String {
    let digest = SHA256.hash(data: Data(projectID.rawValue.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return "embedded_dsh.workspace.validation." + digest
  }

  func workspaceValidationConfiguration(projectID: ProjectID) async throws
    -> WorkbenchValidationConfiguration
  {
    _ = try await registeredProject(projectID.rawValue)
    guard let setting = try await store.setting(key: Self.workspaceValidationKey(projectID)) else {
      return WorkbenchValidationConfiguration(commands: [], timeoutSeconds: 120)
    }
    return try JSONDecoder().decode(
      WorkbenchValidationConfiguration.self, from: Data(setting.value.utf8))
  }

  func workspaceValidationGet(projectID: ProjectID) async throws -> ACPJSONValue {
    let configuration = try await workspaceValidationConfiguration(projectID: projectID)
    return .object([
      "commands": .array(
        configuration.commands.map { command in
          .object([
            "executable": .string(command.executable),
            "arguments": .array(command.arguments.map(ACPJSONValue.string)),
          ])
        }),
      "timeoutSeconds": .integer(Int64(configuration.timeoutSeconds)),
    ])
  }

  func workspaceValidationSet(projectID: ProjectID, input: [String: ACPJSONValue]) async throws
    -> ACPJSONValue
  {
    _ = try await registeredProject(projectID.rawValue)
    guard let commands = input["commands"]?.arrayValue, commands.count <= 3,
      let timeout = input["timeoutSeconds"]?.intValue, (5...120).contains(timeout)
    else { throw ServiceStoreError.invalidArgument("workspace.validation_configuration") }
    var configured: [WorkbenchValidationCommand] = []
    for value in commands {
      guard let entry = value.objectValue, let executable = entry["executable"]?.stringValue,
        !executable.isEmpty, executable.utf8.count <= 1_024, !executable.contains("\0"),
        let args = entry["arguments"]?.arrayValue, args.count <= 64
      else { throw ServiceStoreError.invalidArgument("workspace.validation_command") }
      let arguments = try args.map { item -> String in
        guard let arg = item.stringValue, arg.utf8.count <= 4_096, !arg.contains("\0") else {
          throw ServiceStoreError.invalidArgument("workspace.validation_argument")
        }
        return arg
      }
      _ = try await application.prepareWorkspaceValidationCommand(
        projectID: projectID, executable: executable, arguments: arguments)
      configured.append(WorkbenchValidationCommand(executable: executable, arguments: arguments))
    }
    let configuration = WorkbenchValidationConfiguration(
      commands: configured, timeoutSeconds: timeout)
    let data = try JSONEncoder().encode(configuration)
    guard let value = String(data: data, encoding: .utf8), value.utf8.count <= 32 * 1_024,
      OutboundContentSecurity.redactedSecrets(value, maximumUTF8Bytes: value.utf8.count) == value
    else { throw ServiceStoreError.invalidArgument("workspace.validation_configuration") }
    try await store.setSetting(
      ServiceSettingRecord(
        key: Self.workspaceValidationKey(projectID), value: value, updatedAt: Date()))
    return try await workspaceValidationGet(projectID: projectID)
  }
}
