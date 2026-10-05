import BridgeAgentCore
import BridgeIPC
import Foundation

enum ServiceAgentSetupLogin {
  static func command(
    request: IPCAgentSetupRequest, runtime: ServiceAgentSetupRuntime, paths: ServiceDataPaths
  ) throws -> IPCAgentSetupLoginCommand? {
    if request.providerID == AgentProviderID.deepSeekHarness.rawValue { return nil }
    let source = ToolDiscoveryEnvironment.current()
    let home = try AgentProviderEnvironment.homeDirectory(source: source)
    var environment = [
      "HOME": home,
      "PATH": AgentProviderEnvironment.executableSearchPath(
        executablePath: runtime.nodeExecutablePath ?? runtime.executablePath, source: source),
    ]
    for key in [
      "USERPROFILE", "APPDATA", "LOCALAPPDATA", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
      "QODER_CONFIG_DIR", "QODERCN_CONFIG_DIR", "PI_CODING_AGENT_DIR",
    ] {
      if let value = source[key] { environment[key] = value }
    }
    let spec = specification(request)
    var executable = runtime.executablePath
    var arguments = spec.arguments
    if ["js", "mjs", "cjs"].contains(URL(fileURLWithPath: executable).pathExtension.lowercased()),
      let node = runtime.nodeExecutablePath
    {
      arguments.insert(executable, at: 0)
      executable = node
    }
    return IPCAgentSetupLoginCommand(
      executablePath: executable, arguments: arguments,
      workingDirectory: paths.supervisorScratchURL.path, environment: environment,
      instructions: spec.instructions, documentationURL: spec.url)
  }

  private static func specification(_ request: IPCAgentSetupRequest)
    -> (arguments: [String], instructions: String, url: String)
  {
    switch AgentProviderID(rawValue: request.providerID) {
    case .openCode:
      return (
        ["auth", "login"], "在打开的终端中选择服务商，完成浏览器登录或填写 API Key，然后返回验证。",
        "https://opencode.ai/docs/cli/"
      )
    case .pi:
      return (
        [], "在 Pi 中输入 /login，选择服务商并完成登录或 API 配置，然后退出并返回验证。",
        "https://github.com/earendil-works/pi/blob/main/packages/coding-agent/README.md"
      )
    case .qoder:
      return (
        ["login"], "请使用所选地区的账号完成原生登录，然后返回验证连接。",
        request.qoderDistribution == QoderDistribution.cn.rawValue
          ? "https://help.aliyun.com/zh/lingma/qoder-cli-cn-get-started-quickly"
          : "https://docs.qoder.com/cli/authentication"
      )
    default:
      return (
        [], "按终端指引完成浏览器登录；如提示授权码，请回到终端填写，然后返回验证。",
        "https://antigravity.google/docs/cli/install/"
      )
    }
  }
}
