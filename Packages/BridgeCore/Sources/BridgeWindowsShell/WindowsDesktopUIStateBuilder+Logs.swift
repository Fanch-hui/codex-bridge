#if os(Windows)
  import BridgeDesktopUI

  extension WindowsDesktopUIStateBuilder {
    static func logsPage(_ display: WindowsLogDisplay?) -> BridgeDesktopLogsState? {
      guard let display else { return nil }
      return BridgeDesktopLogsState(
        header: header(
          "日志",
          "检查任务事件、命令、文件与错误证据。",
          "list.dash.header.rectangle"
        ),
        searchText: display.searchText,
        projectOptions: display.projectOptions,
        selectedProjectID: display.selectedProjectID,
        kindOptions: kindOptions,
        selectedKind: display.selectedKind,
        rows: display.rowsTyped,
        selectedRowID: display.selectedRowID,
        detailText: display.detailText,
        canCopy: display.copyEnabled,
        canRefresh: display.refreshEnabled
      )
    }

    private static let kindOptions = [
      choice("all", "全部类型"),
      choice("command", "命令"),
      choice("file", "文件"),
      choice("other", "其他"),
    ]
  }
#endif
