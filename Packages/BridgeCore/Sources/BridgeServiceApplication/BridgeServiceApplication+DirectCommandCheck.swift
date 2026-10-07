import BridgeDirectCommand
import BridgeMCP
import BridgeSecurity
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func serviceCheckDirectCommand(
    projectID: String, commandLine: String, workingDirectory: String? = nil,
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceDirectCommandCheckResult {
    try Self.checkDeadline(deadline)
    let project = try await applyingDirectConfiguration(to: readableProject(projectID))
    let argv: [String]
    do {
      argv = try DirectCommandLine.parse(commandLine)
    } catch {
      return ServiceDirectCommandCheckResult(
        allowed: false, code: "invalid_command_line",
        message: "命令格式不正确：请输入一条完整命令，使用引号包裹带空格的参数。",
        nextAction: "不支持管道、重定向或多条命令，请分别校验。")
    }
    let request = MCPDirectExecRequest(
      projectID: projectID, argv: argv, workingDirectory: workingDirectory)
    return try await checkResolvedDirectCommand(request, project: project, deadline: deadline)
  }

  private func checkResolvedDirectCommand(
    _ request: MCPDirectExecRequest, project: ServiceProjectRecord,
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceDirectCommandCheckResult {
    do {
      let resolution = try resolveDirectCommandPolicy(request, project: project)
      guard resolution.allowed else { return Self.directCommandDenial(resolution) }
      let directory = try Self.resolvedWorkingDirectory(
        project: project, relative: resolution.workingDirectory)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        return Self.directCommandCheckFailure(
          "working_directory_missing", "工作目录不存在或不是目录。",
          nextAction: "请选择已注册项目内存在的目录。", resolution: resolution)
      }
      let launchArgv = try Self.resolvedLaunchArgv(resolution.argv, project: project)
      guard let executable = launchArgv.first,
        FileManager.default.fileExists(atPath: executable, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else {
        return Self.directCommandCheckFailure(
          "executable_missing", "未找到命令的可执行文件。",
          nextAction: "检查程序是否已安装；必要时输入可执行文件的完整路径。", resolution: resolution)
      }
      #if !os(Windows)
        guard FileManager.default.isExecutableFile(atPath: executable) else {
          return Self.directCommandCheckFailure(
            "executable_not_executable", "命令文件没有执行权限。",
            nextAction: "请在本机确认该文件的执行权限。", resolution: resolution)
        }
      #endif
      let requiresApproval = try await settings.directApprovalMode() != .auto
      try Self.checkDeadline(deadline)
      return ServiceDirectCommandCheckResult(
        allowed: true, code: "allowed", message: Self.directCommandAllowedMessage(resolution),
        matchedRule: Self.redactedCommandCheckValue(resolution.matchedRule),
        ruleSource: resolution.ruleSource,
        executable: Self.redactedCommandCheckValue(executable),
        workingDirectory: Self.redactedCommandCheckValue(directory),
        requiresApproval: requiresApproval,
        nextAction: requiresApproval
          ? "实际执行仍需本机审批；校验结果不代表程序或脚本内容安全。"
          : "实际执行会重新校验；校验结果不代表程序或脚本内容安全。")
    } catch let error as BridgeMCPQueryError {
      switch error {
      case .pathDenied, .pathChanged:
        return Self.directCommandCheckFailure(
          "path_denied", "工作目录或项目内可执行文件路径不符合项目目录边界。",
          nextAction: "工作目录请填写项目内相对路径，并检查符号链接目标。")
      case .processLaunchFailed:
        return Self.directCommandCheckFailure(
          "executable_missing", "未找到命令的可执行文件。",
          nextAction: "检查程序是否已安装；必要时输入可执行文件的完整路径。")
      default:
        throw error
      }
    }
  }

  private static func directCommandDenial(_ resolution: DirectCommandResolution)
    -> ServiceDirectCommandCheckResult
  {
    let code: String
    let message: String
    let nextAction: String
    switch resolution.reason {
    case .commandModeDenied:
      code = "command_mode_denied"
      message = "当前命令模式禁止执行命令。"
      nextAction = "如需执行，请在本机 Direct 设置中调整命令模式。"
    case .blacklisted:
      code = "command_blacklisted"
      message = "命令命中黑名单；黑名单优先于白名单和完整模式。"
      nextAction = "请在本机 Direct 设置中核对命中的黑名单规则。"
    case .invalidArguments:
      code = "invalid_arguments"
      message = "命令参数不符合当前规则或项目路径约束。"
      nextAction = "请检查参数数量、内置命令支持的参数和项目目录边界。"
    case .commandNotRegistered, .unknownCommand, nil:
      code = "command_not_registered"
      message = "安全模式下，命令未匹配白名单、内置规则或项目内可执行文件。"
      nextAction = "如需允许该命令，请在本机 Direct 设置中配置对应参数前缀。"
    }
    return directCommandCheckFailure(code, message, nextAction: nextAction, resolution: resolution)
  }

  private static func directCommandAllowedMessage(_ resolution: DirectCommandResolution) -> String {
    switch resolution.ruleSource {
    case "whitelist": "命令匹配白名单参数前缀，允许通过命令策略。"
    case "built_in": "命令符合内置规则及参数约束，允许通过命令策略。"
    case "project_local": "可执行文件位于项目目录内，允许通过命令策略。"
    default: "完整模式允许该命令，且未命中黑名单。"
    }
  }

  private static func directCommandCheckFailure(
    _ code: String, _ message: String, nextAction: String,
    resolution: DirectCommandResolution? = nil
  ) -> ServiceDirectCommandCheckResult {
    ServiceDirectCommandCheckResult(
      allowed: false, code: code, message: message,
      matchedRule: redactedCommandCheckValue(resolution?.matchedRule),
      ruleSource: resolution?.ruleSource, nextAction: nextAction)
  }

  private static func redactedCommandCheckValue(_ value: String?) -> String? {
    value.map { OutboundContentSecurity.redactedCommand($0, maximumUTF8Bytes: 4096) }
  }
}
