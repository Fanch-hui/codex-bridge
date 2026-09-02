import AppKit
import BridgeDesktopUI

extension BridgeDesktopCommandRouter {
  static func handleLogs(
    _ envelope: BridgeDesktopCommandEnvelope,
    model: BridgeServiceAppModel
  ) {
    let payload = envelope.payload
    switch envelope.command {
    case .selectLog:
      guard let logID = validatedID(payload.logID, maximumBytes: 512),
        BridgeDesktopLogPresentation.rows(from: model).contains(where: { $0.id == logID })
      else { return }
      model.desktopSelectedLogID = logID
    case .refreshLogs:
      model.refresh()
    case .setLogSearch:
      guard let search = validatedText(payload.searchText, maximumBytes: 4_096) else { return }
      model.desktopLogSearchText = search
      model.desktopSelectedLogID = nil
    case .setLogProjectFilter:
      guard let projectID = payload.projectID else {
        model.desktopLogProjectID = nil
        model.desktopSelectedLogID = nil
        return
      }
      guard project(projectID, in: model) != nil else { return }
      model.desktopLogProjectID = validatedID(projectID)
      model.desktopSelectedLogID = nil
    case .setLogKindFilter:
      guard let kind = validatedID(payload.kind, maximumBytes: 32),
        BridgeDesktopLogPresentation.kindOptions.contains(where: { $0.id == kind })
      else { return }
      model.desktopLogKind = kind
      model.desktopSelectedLogID = nil
    case .copyLogs:
      guard connected(model) else { return }
      let text = BridgeDesktopLogPresentation.copyText(
        rows: BridgeDesktopLogPresentation.rows(from: model)
      )
      guard !text.isEmpty else { return }
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(text, forType: .string)
      model.postToast("已复制日志记录", symbol: "doc.on.doc")
    default:
      return
    }
  }
}
