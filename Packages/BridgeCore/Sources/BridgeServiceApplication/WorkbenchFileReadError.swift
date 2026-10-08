import Foundation

public enum WorkbenchFileReadError: Error, LocalizedError, Equatable, Sendable {
  case binaryFile
  case fileTooLarge(maximumBytes: Int)

  public var errorDescription: String? {
    switch self {
    case .binaryFile:
      "此文件不是 UTF-8 文本，无法在文本编辑器中打开。"
    case .fileTooLarge(let maximumBytes):
      "此文件超过当前文本读取上限（\(maximumBytes / 1_024) KiB）。"
    }
  }
}
