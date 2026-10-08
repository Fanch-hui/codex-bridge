import Foundation

public enum BridgeDesktopUIResource: String, CaseIterable, Sendable {
  case indexHTML = "index.html"
  case hostContextJS = "host-context.js"
  case stylesCSS = "styles.css"
  case pagesCSS = "pages.css"
  case markdownCSS = "markdown.css"
  case workbenchCSS = "workbench.css"
  case dshWorkbenchCSS = "dsh-workbench.css"
  case dshWorkspaceCSS = "dsh-workspace.css"
  case responsiveCSS = "responsive.css"
  case windowsThemeCSS = "windows-theme.css"
  case windowsComponentsCSS = "windows-components.css"
  case detailPagesCSS = "detail-pages.css"
  case pagesCommonJS = "pages-common.js"
  case pagesDetailJS = "pages-detail.js"
  case pagesNativePermissionsJS = "pages-native-permissions.js"
  case pagesWorkbenchConversationJS = "pages-workbench-conversation.js"
  case pagesWorkbenchProcessJS = "pages-workbench-process.js"
  case pagesWorkbenchConversationIncrementalJS = "pages-workbench-conversation-incremental.js"
  case pagesWorkbenchSkillsJS = "pages-workbench-skills.js"
  case pagesWorkbenchAttachmentsJS = "pages-workbench-attachments.js"
  case pagesWorkbenchControlsJS = "pages-workbench-controls.js"
  case pagesWorkbenchSubmissionsJS = "pages-workbench-submissions.js"
  case pagesWorkbenchSplitJS = "pages-workbench-split.js"
  case pagesWorkbenchHistorySearchJS = "pages-workbench-history-search.js"
  case pagesWorkbenchHeaderJS = "pages-workbench-header.js"
  case pagesNativeSessionDirectoryJS = "pages-native-session-directory.js"
  case pagesWorkbenchActionsJS = "pages-workbench-actions.js"
  case pagesWorkbenchHandoffJS = "pages-workbench-handoff.js"
  case pagesWorkbenchApprovalsJS = "pages-workbench-approvals.js"
  case pagesWorkbenchDetailsJS = "pages-workbench-details.js"
  case pagesWorkbenchJS = "pages-workbench.js"
  case pagesDSHWorkbenchJS = "pages-dsh-workbench.js"
  case pagesDSHWorkbenchLayoutJS = "pages-dsh-workbench-layout.js"
  case pagesDSHWorkbenchSelectionJS = "pages-dsh-workbench-selection.js"
  case pagesDSHConversationJS = "pages-dsh-conversation.js"
  case pagesDSHComposerViewJS = "pages-dsh-composer-view.js"
  case pagesDSHWorkbenchComposerJS = "pages-dsh-workbench-composer.js"
  case pagesDSHSessionsJS = "pages-dsh-sessions.js"
  case pagesDSHWorkspaceEditorJS = "pages-dsh-workspace-editor.js"
  case pagesDSHWorkspaceJS = "pages-dsh-workspace.js"
  case pagesDSHSettingsJS = "pages-dsh-settings.js"
  case pagesFormDraftJS = "pages-form-draft.js"
  case pagesAgentConnectorDetailsJS = "pages-agent-connector-details.js"
  case pagesAgentHeadlessConsentJS = "pages-agent-headless-consent.js"
  case pagesAgentQoderSettingsJS = "pages-agent-qoder-settings.js"
  case pagesAgentSetupJS = "pages-agent-setup.js"
  case pagesAgentDSHDesktopJS = "pages-agent-dsh-desktop.js"
  case pagesAgentConnectorRowJS = "pages-agent-connector-row.js"
  case pagesAgentConnectorsJS = "pages-agent-connectors.js"
  case pagesCodexConnectionJS = "pages-codex-connection.js"
  case pagesDeepSeekHarnessMCPEditorJS = "pages-deepseek-harness-mcp-editor.js"
  case pagesDeepSeekHarnessMCPJS = "pages-deepseek-harness-mcp.js"
  case pagesProjectCollectionsJS = "pages-project-collections.js"
  case pagesProjectsJS = "pages-projects.js"
  case pagesLogsJS = "pages-logs.js"
  case pagesConnectionsEditorJS = "pages-connections-editor.js"
  case pagesConnectionsClientsJS = "pages-connections-clients.js"
  case pagesConnectionsNavigationJS = "pages-connections-navigation.js"
  case pagesConnectionsTunnelJS = "pages-connections-tunnel.js"
  case pagesConnectionsJS = "pages-connections.js"
  case pagesSettingsModelsJS = "pages-settings-models.js"
  case pagesSettingsAgentsJS = "pages-settings-agents.js"
  case pagesSettingsQoderPermissionsJS = "pages-settings-qoder-permissions.js"
  case pagesSettingsInstructionsJS = "pages-settings-instructions.js"
  case pagesDirectJS = "pages-direct.js"
  case pagesSettingsNavigationJS = "pages-settings-navigation.js"
  case pagesSettingsJS = "pages-settings.js"
  case feedbackJS = "feedback.js"
  case sidebarJS = "sidebar.js"
  case iconsJS = "icons.js"
  case appJS = "app.js"
  case appUpdateJS = "app-update.js"
  case pagesJS = "pages.js"
}

public enum BridgeDesktopUIResources {
  public static func url(for resource: BridgeDesktopUIResource) -> URL? {
    Bundle.module.url(forResource: resource.rawValue, withExtension: nil)
  }

  public static func read(_ resource: BridgeDesktopUIResource) throws -> String {
    guard let url = url(for: resource) else {
      throw NSError(
        domain: "BridgeDesktopUIResources",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Missing bundled resource: \(resource.rawValue)"]
      )
    }
    return try String(contentsOf: url, encoding: .utf8)
  }
}

public enum BridgeDesktopUI {
  public static func indexURL() -> URL? {
    BridgeDesktopUIResources.url(for: .indexHTML)
  }

  public static func resourceURL(_ resource: BridgeDesktopUIResource) -> URL? {
    BridgeDesktopUIResources.url(for: resource)
  }
}
