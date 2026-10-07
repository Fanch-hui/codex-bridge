import Foundation

public enum AppUpdateFailurePresentation {
  public static func message(_ error: Error, phase: String) -> String {
    var stage = phase
    if let updateError = error as? AppUpdateError {
      switch updateError {
      case .sizeMismatch, .checksumMismatch: stage = "verifying"
      default: break
      }
    }
    let title: String
    switch stage {
    case "checking": title = "检查更新失败"
    case "downloading": title = "下载更新失败"
    case "verifying": title = "验证更新包失败"
    case "waiting": title = "准备安装失败"
    default: title = "安装更新失败"
    }
    return "\(title)：\(error.localizedDescription)"
  }
}
