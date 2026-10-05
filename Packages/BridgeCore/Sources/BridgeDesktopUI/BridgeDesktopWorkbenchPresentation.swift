import Foundation

public enum BridgeDesktopWorkbenchPermissionMode: String, CaseIterable, Equatable, Sendable {
  case readOnly = "read-only"
  case full = "full"

  public var title: String {
    switch self {
    case .readOnly: "只读"
    case .full: "完整"
    }
  }

  public var detail: String {
    switch self {
    case .readOnly: "允许读取，禁止写入和联网"
    case .full: "允许读取、写入和联网"
    }
  }

  public var choice: BridgeDesktopChoice {
    BridgeDesktopChoice(id: rawValue, title: title, detail: detail)
  }

  public static var choices: [BridgeDesktopChoice] {
    allCases.map(\.choice)
  }
}

public enum BridgeDesktopWorkbenchPresentation {
  public static func steerModes(supportsImmediateSteer: Bool) -> [BridgeDesktopChoice] {
    var modes = [BridgeDesktopChoice(id: "queued", title: "当前任务结束后继续")]
    if supportsImmediateSteer {
      modes.append(
        BridgeDesktopChoice(
          id: "interrupt-current-then-continue",
          title: "中断当前任务并继续"
        )
      )
    }
    return modes
  }

  public static func statusTone(for status: String) -> String {
    switch status {
    case "running", "starting", "运行中", "正在启动":
      BridgeDesktopStatusTone.running.rawValue
    case "completed", "已完成", "已创建": BridgeDesktopStatusTone.success.rawValue
    case "failed", "失败": BridgeDesktopStatusTone.error.rawValue
    case "awaiting_local_approval", "waiting_for_codex_approval", "等待回答",
      "等待本机批准", "等待 Codex 审批":
      BridgeDesktopStatusTone.warning.rawValue
    default: BridgeDesktopStatusTone.neutral.rawValue
    }
  }
}
