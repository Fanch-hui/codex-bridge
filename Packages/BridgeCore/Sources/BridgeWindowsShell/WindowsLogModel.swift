#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore
  import Foundation

  @MainActor
  final class WindowsLogModel {
    let client: any BridgeServiceClientProtocol
    let displayBox: AuxiliaryDisplayBox<WindowsLogDisplay>
    let feedback: WindowsDesktopFeedbackStore

    private(set) var connectionState: WindowsWorkbenchDisplay.ConnectionState = .idle
    private(set) var items: [TaskLogPresentation.Item] = []
    private(set) var projectNames: [String] = []
    private(set) var projectIDs: [String] = []
    private(set) var desktopRows: [BridgeDesktopLogRow] = []
    var searchText = ""
    var selectedProjectIndex = 0
    var selectedKindIndex = 0
    var selectedItemID: String?
    private var busy = false
    private var statusText = "尚未加载任务日志。"

    init(
      client: any BridgeServiceClientProtocol,
      feedback: WindowsDesktopFeedbackStore
    ) {
      self.client = client
      self.feedback = feedback
      displayBox = AuxiliaryDisplayBox(
        value: WindowsLogDisplay(
          connectionState: .idle,
          searchText: "",
          projectRows: ["全部项目"],
          selectedProjectIndex: 0,
          kindRows: Self.kindRows,
          selectedKindIndex: 0,
          rows: [],
          selectedIndex: nil,
          detailText: "暂无任务事件。",
          refreshEnabled: false,
          copyEnabled: false,
          copyText: "",
          statusText: statusText
        )
      )
    }

    func refresh() async {
      guard !busy else { return }
      busy = true
      statusText = "正在读取任务日志…"
      publishDisplay()
      defer {
        busy = false
        publishDisplay()
      }
      do {
        _ = try await client.status()
        connectionState = .connected
        let projects = (try? await client.projects()) ?? []
        let tasks = try await client.tasks(IPCTaskListRequest(limit: 200))
        let names = Dictionary(uniqueKeysWithValues: projects.map { ($0.projectID, $0.name) })
        let sortedProjects = projects.sorted {
          $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        projectNames = sortedProjects.map(\.name)
        projectIDs = sortedProjects.map(\.projectID)
        selectedProjectIndex = min(selectedProjectIndex, projectNames.count)
        items = TaskLogPresentation.flatten(tasks: tasks, projectNames: names)
        desktopRows = Self.desktopRows(tasks: tasks, projectNames: names)
        reconcileSelection()
        statusText = "已加载 \(items.count) 条任务事件。"
      } catch {
        statusText = "任务日志读取失败：\(BridgeServiceErrorMessage.message(error))"
      }
      publishDisplay()
    }

    func selectItem(at index: Int) {
      let filtered = filteredItems
      guard filtered.indices.contains(index) else { return }
      selectedItemID = filtered[index].id
      publishDisplay()
    }

    func setSearchText(_ text: String) {
      guard searchText != text else { return }
      searchText = text
      reconcileSelection()
      publishDisplay()
    }

    func setProjectFilter(_ index: Int) {
      guard (0...projectNames.count).contains(index), selectedProjectIndex != index else { return }
      selectedProjectIndex = index
      reconcileSelection()
      publishDisplay()
    }

    func setKindFilter(_ index: Int) {
      guard Self.kindRows.indices.contains(index), selectedKindIndex != index else { return }
      selectedKindIndex = index
      reconcileSelection()
      publishDisplay()
    }

    func didCopy(_ success: Bool) {
      statusText = success ? "已复制 \(filteredItems.count) 条日志记录。" : "复制日志失败。"
      if success {
        feedback.postToast(statusText)
      } else {
        feedback.postAlert(statusText, title: "复制失败")
      }
      publishDisplay()
    }

    func refreshDisplaySnapshot() { publishDisplay() }

    private func reconcileSelection() {
      let filtered = filteredItems
      if let selectedItemID, filtered.contains(where: { $0.id == selectedItemID }) { return }
      selectedItemID = filtered.first?.id
    }

    private func publishDisplay() {
      let filtered = filteredItems
      let selectedIndex = selectedItemID.flatMap { id in filtered.firstIndex { $0.id == id } }
      let selected = selectedIndex.flatMap { filtered[$0] }
      let selectedProjectID =
        selectedProjectIndex > 0 && projectIDs.indices.contains(selectedProjectIndex - 1)
        ? projectIDs[selectedProjectIndex - 1] : nil
      let value = WindowsLogDisplay(
        connectionState: connectionState,
        searchText: searchText,
        projectRows: ["全部项目"] + projectNames,
        selectedProjectIndex: selectedProjectIndex,
        kindRows: Self.kindRows,
        selectedKindIndex: selectedKindIndex,
        rows: filtered.map(\.rowText),
        selectedIndex: selectedIndex,
        detailText: selected?.detailText ?? "暂无任务事件。",
        refreshEnabled: connectionState == .connected && !busy,
        copyEnabled: !filtered.isEmpty,
        copyText: filtered.map(\.rowText).joined(separator: "\r\n"),
        statusText: "\(statusText) 当前显示 \(filtered.count) 条。",
        rowsTyped: filteredDesktopRows,
        projectOptions: desktopProjectOptions,
        selectedProjectID: selectedProjectID,
        selectedKind: selectedKindID,
        selectedRowID: selectedItemID
      )
      displayBox.store(value)
    }

    private var filteredItems: [TaskLogPresentation.Item] {
      let visibleIDs = Set(filteredDesktopRows.map(\.id))
      return items.filter { visibleIDs.contains($0.id) }
    }

    private var filteredDesktopRows: [BridgeDesktopLogRow] {
      let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let projectID =
        selectedProjectIndex > 0 && projectIDs.indices.contains(selectedProjectIndex - 1)
        ? projectIDs[selectedProjectIndex - 1] : nil
      let kind = selectedKindID == "all" ? nil : selectedKindID
      return desktopRows.filter { row in
        if let projectID, row.projectID != projectID { return false }
        if let kind, row.kind != kind { return false }
        guard !query.isEmpty else { return true }
        return [row.projectName, row.summary, row.kindLabel, row.taskID].contains {
          $0.lowercased().contains(query)
        }
      }
    }

    private var desktopProjectOptions: [BridgeDesktopChoice] {
      [BridgeDesktopChoice(id: "all", title: "全部项目")]
        + zip(projectIDs, projectNames).map { id, name in
          BridgeDesktopChoice(id: id, title: name)
        }
    }

    private var selectedKindID: String {
      switch selectedKindIndex {
      case 1: "command"
      case 2: "file"
      case 3: "other"
      default: "all"
      }
    }

    private static func desktopRows(
      tasks: [MCPServiceTaskSnapshot],
      projectNames: [String: String]
    ) -> [BridgeDesktopLogRow] {
      tasks.flatMap { task in
        task.recentEvents.map { event in
          let category = category(kind: event.kind, summary: event.summary)
          return BridgeDesktopLogRow(
            id: "\(task.taskID)_\(event.sequence)",
            sequence: event.sequence,
            taskID: task.taskID,
            projectID: task.projectID,
            projectName: projectNames[task.projectID] ?? task.projectID,
            kind: category,
            kindLabel: kindLabel(category, rawKind: event.kind, summary: event.summary),
            summary: event.summary,
            timestamp: event.occurredAt
          )
        }
      }.sorted { $0.sequence > $1.sequence }
    }

    private static func category(kind: String, summary: String) -> String {
      let rawKind = kind.lowercased()
      let detail = summary.lowercased()
      if rawKind.contains("file") || detail.contains("file") || detail.contains("edit")
        || detail.contains("write")
      {
        return "file"
      }
      if rawKind.contains("command") || detail.contains("command") || detail.contains("exec")
        || detail.contains("run")
      {
        return "command"
      }
      return "other"
    }

    private static func kindLabel(
      _ kind: String,
      rawKind: String,
      summary: String
    ) -> String {
      switch kind {
      case "command": "命令"
      case "file": "文件"
      default:
        "\(rawKind) \(summary)".lowercased().contains("error")
          || "\(rawKind) \(summary)".lowercased().contains("failed")
          ? "错误" : "事件"
      }
    }

    private static let kindRows = ["全部类型", "命令", "文件", "其他"]
  }
#endif
