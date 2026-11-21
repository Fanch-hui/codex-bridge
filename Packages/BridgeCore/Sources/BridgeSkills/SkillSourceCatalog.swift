import BridgeAgentCore
import Foundation

public enum SkillSourceCatalog {
  private struct SourceSpec: Sendable {
    let id: String
    let displayName: String
    let kind: SkillSourceKind
    let defaultPriority: Int
    let defaultEnabled: Bool
    let isOptionalNoise: Bool
    let scanMode: SkillSourceScanMode
    let roots: @Sendable (_ env: [String: String], _ home: URL) -> [String]
  }

  public static func projectSources(for projectRoot: URL) -> [SkillSourceDefinition] {
    let root = projectRoot.standardizedFileURL
    let specs: [(id: String, sub: String, label: String, priority: Int)] = [
      ("project-dsh", ".dsh/skills", "项目 (.dsh/skills)", 10),
      ("project-agents", ".agents/skills", "项目 (.agents/skills)", 20),
      ("project-codex", ".codex/skills", "项目 (.codex/skills)", 30),
      ("project-claude", ".claude/skills", "项目 (.claude/skills)", 40),
      ("project-opencode", ".opencode/skills", "项目 (.opencode/skills)", 50),
      ("project-cursor", ".cursor/skills", "项目 (.cursor/skills)", 60),
      ("project-gemini", ".gemini/skills", "项目 (.gemini/skills)", 70),
      ("project-skills", "skills", "项目 (skills/)", 80),
    ]
    return specs.map { spec in
      SkillSourceDefinition(
        id: spec.id,
        displayName: spec.label,
        kind: .project,
        roots: [root.appendingPathComponent(spec.sub, isDirectory: true).path],
        defaultPriority: spec.priority,
        defaultEnabled: true
      )
    }
  }

  public static func globalSources(
    managedSkillsRoot: URL,
    policy: SkillHubPolicy = SkillHubPolicy(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    fixedGlobalRoots: [URL]? = nil
  ) -> [SkillSourceDefinition] {
    let managedPath = managedSkillsRoot.standardizedFileURL.path
    if let fixedGlobalRoots {
      return fixedSources(
        managedPath: managedPath,
        fixedGlobalRoots: fixedGlobalRoots,
        policy: policy
      )
    }

    let home = resolvedHomeDirectory(environment: environment, fallback: homeDirectory)
    var definitions: [SkillSourceDefinition] = [
      SkillSourceDefinition(
        id: "bridge-managed",
        displayName: "Bridge 自管库",
        kind: .bridgeManaged,
        roots: [managedPath],
        defaultPriority: 100,
        defaultEnabled: true,
        isWritable: true
      )
    ]

    for spec in builtInSpecs {
      let roots = uniquePaths(spec.roots(environment, home), excluding: managedPath)
      definitions.append(
        SkillSourceDefinition(
          id: spec.id,
          displayName: spec.displayName,
          kind: spec.kind,
          roots: roots,
          defaultPriority: spec.defaultPriority,
          defaultEnabled: spec.defaultEnabled,
          isOptionalNoise: spec.isOptionalNoise,
          scanMode: spec.scanMode
        )
      )
    }

    for (index, custom) in policy.customDirectories.enumerated() {
      definitions.append(
        SkillSourceDefinition(
          id: custom.id,
          displayName: custom.name.isEmpty
            ? URL(fileURLWithPath: custom.path).lastPathComponent : custom.name,
          kind: .custom,
          roots: [URL(fileURLWithPath: custom.path, isDirectory: true).standardizedFileURL.path],
          defaultPriority: 1300 + index,
          defaultEnabled: custom.enabled,
          isCustom: true
        )
      )
    }

    return applyOrder(definitions, customOrder: policy.sourceOrder)
  }

  private static func fixedSources(
    managedPath: String,
    fixedGlobalRoots: [URL],
    policy: SkillHubPolicy
  ) -> [SkillSourceDefinition] {
    var result: [SkillSourceDefinition] = []
    if !fixedGlobalRoots.contains(where: { $0.standardizedFileURL.path == managedPath }) {
      result.append(
        SkillSourceDefinition(
          id: "bridge-managed",
          displayName: "Bridge 自管库",
          kind: .bridgeManaged,
          roots: [managedPath],
          defaultPriority: 100,
          defaultEnabled: true,
          isWritable: true
        )
      )
    }
    for (index, url) in fixedGlobalRoots.enumerated() {
      let path = url.standardizedFileURL.path
      let writable = path == managedPath
      result.append(
        SkillSourceDefinition(
          id: writable ? "bridge-managed" : "fixed-\(index)",
          displayName: writable ? "Bridge 自管库" : url.lastPathComponent,
          kind: writable ? .bridgeManaged : .custom,
          roots: [path],
          defaultPriority: writable ? 100 : (200 + index * 10),
          defaultEnabled: true,
          isWritable: writable
        )
      )
    }
    for (index, custom) in policy.customDirectories.enumerated() {
      result.append(
        SkillSourceDefinition(
          id: custom.id,
          displayName: custom.name,
          kind: .custom,
          roots: [URL(fileURLWithPath: custom.path, isDirectory: true).standardizedFileURL.path],
          defaultPriority: 1300 + index,
          defaultEnabled: custom.enabled,
          isCustom: true
        )
      )
    }
    return applyOrder(result, customOrder: policy.sourceOrder)
  }

  private static func applyOrder(
    _ definitions: [SkillSourceDefinition],
    customOrder: [String]
  ) -> [SkillSourceDefinition] {
    guard !customOrder.isEmpty else {
      return definitions.sorted { $0.defaultPriority < $1.defaultPriority }
    }
    let indexByID = Dictionary(
      customOrder.enumerated().map { ($0.element, $0.offset) },
      uniquingKeysWith: { first, _ in first }
    )
    return definitions.sorted { lhs, rhs in
      let leftRank = indexByID[lhs.id] ?? (10_000 + lhs.defaultPriority)
      let rightRank = indexByID[rhs.id] ?? (10_000 + rhs.defaultPriority)
      if leftRank != rightRank { return leftRank < rightRank }
      return lhs.defaultPriority < rhs.defaultPriority
    }.enumerated().map { offset, item in
      SkillSourceDefinition(
        id: item.id,
        displayName: item.displayName,
        kind: item.kind,
        roots: item.roots,
        defaultPriority: (offset + 1) * 100,
        defaultEnabled: item.defaultEnabled,
        isWritable: item.isWritable,
        isOptionalNoise: item.isOptionalNoise,
        isCustom: item.isCustom,
        scanMode: item.scanMode
      )
    }
  }

  private static let builtInSpecs: [SourceSpec] = [
    SourceSpec(
      id: "agents-shared",
      displayName: "Agents 共享 (~/.agents)",
      kind: .agentsShared,
      defaultPriority: 200,
      defaultEnabled: true,
      isOptionalNoise: false,
      scanMode: .standardDirectory,
      roots: { env, home in
        var list: [String] = []
        if let configured = envPath("DSH_AGENTS_HOME", in: env) {
          list.append(joined(configured, "skills"))
        }
        list.append(home.appendingPathComponent(".agents/skills", isDirectory: true).path)
        return list
      }
    ),
    SourceSpec(
      id: "codex",
      displayName: "Codex",
      kind: .codex,
      defaultPriority: 300,
      defaultEnabled: true,
      isOptionalNoise: false,
      scanMode: .standardDirectory,
      roots: { env, home in
        var list: [String] = []
        if let codexHome = envPath("CODEX_HOME", in: env) {
          list.append(joined(codexHome, "skills"))
        }
        list.append(home.appendingPathComponent(".codex/skills", isDirectory: true).path)
        return list
      }
    ),
    SourceSpec(
      id: "claude-code",
      displayName: "Claude Code",
      kind: .claudeCode,
      defaultPriority: 400,
      defaultEnabled: true,
      isOptionalNoise: false,
      scanMode: .standardDirectory,
      roots: { env, home in
        var list: [String] = []
        if let claudeDir = envPath("CLAUDE_CONFIG_DIR", in: env) {
          list.append(joined(claudeDir, "skills"))
        }
        list.append(home.appendingPathComponent(".claude/skills", isDirectory: true).path)
        return list
      }
    ),
    SourceSpec(
      id: "dsh",
      displayName: "独立 DSH",
      kind: .dsh,
      defaultPriority: 500,
      defaultEnabled: true,
      isOptionalNoise: false,
      scanMode: .standardDirectory,
      roots: { _, home in
        [home.appendingPathComponent(".dsh/skills", isDirectory: true).path]
      }
    ),
    SourceSpec(
      id: "opencode",
      displayName: "OpenCode",
      kind: .openCode,
      defaultPriority: 600,
      defaultEnabled: true,
      isOptionalNoise: false,
      scanMode: .standardDirectory,
      roots: { env, home in
        var list: [String] = []
        if let xdg = envPath("XDG_CONFIG_HOME", in: env) {
          list.append(joined(xdg, "opencode/skills"))
        }
        list.append(home.appendingPathComponent(".config/opencode/skills", isDirectory: true).path)
        #if os(Windows)
          if let appData = envPath("APPDATA", in: env) {
            list.append(joined(appData, "opencode/skills"))
          }
        #endif
        list.append(home.appendingPathComponent(".opencode/skills", isDirectory: true).path)
        return list
      }
    ),
    SourceSpec(
      id: "gemini-antigravity",
      displayName: "Antigravity / Gemini",
      kind: .geminiAntigravity,
      defaultPriority: 700,
      defaultEnabled: true,
      isOptionalNoise: false,
      scanMode: .standardDirectory,
      roots: { _, home in
        [
          home.appendingPathComponent(".gemini/antigravity/skills", isDirectory: true).path,
          home.appendingPathComponent(".gemini/config/skills", isDirectory: true).path,
          home.appendingPathComponent(".gemini/skills", isDirectory: true).path,
        ]
      }
    ),
    SourceSpec(
      id: "pi",
      displayName: "Pi",
      kind: .pi,
      defaultPriority: 800,
      defaultEnabled: true,
      isOptionalNoise: false,
      scanMode: .standardDirectory,
      roots: { env, home in
        var list: [String] = []
        if let piDir = envPath("PI_CODING_AGENT_DIR", in: env) {
          list.append(joined(piDir, "skills"))
        }
        list.append(home.appendingPathComponent(".pi/agent/skills", isDirectory: true).path)
        return list
      }
    ),
    SourceSpec(
      id: "qoder",
      displayName: "Qoder",
      kind: .qoder,
      defaultPriority: 900,
      defaultEnabled: true,
      isOptionalNoise: false,
      scanMode: .standardDirectory,
      roots: { _, home in [home.appendingPathComponent(".qoder/skills", isDirectory: true).path] }
    ),
    SourceSpec(
      id: "qoder-cn",
      displayName: "Qoder CN",
      kind: .qoder,
      defaultPriority: 910,
      defaultEnabled: true,
      isOptionalNoise: false,
      scanMode: .standardDirectory,
      roots: { _, home in [home.appendingPathComponent(".qoder-cn/skills", isDirectory: true).path]
      }
    ),
    SourceSpec(
      id: "cursor",
      displayName: "Cursor",
      kind: .cursor,
      defaultPriority: 1000,
      defaultEnabled: true,
      isOptionalNoise: false,
      scanMode: .standardDirectory,
      roots: { _, home in [home.appendingPathComponent(".cursor/skills", isDirectory: true).path] }
    ),
    SourceSpec(
      id: "devin",
      displayName: "Devin",
      kind: .devin,
      defaultPriority: 1100,
      defaultEnabled: true,
      isOptionalNoise: false,
      scanMode: .standardDirectory,
      roots: { _, home in [home.appendingPathComponent(".devin/skills", isDirectory: true).path] }
    ),
    SourceSpec(
      id: "windsurf",
      displayName: "Windsurf",
      kind: .windsurf,
      defaultPriority: 1200,
      defaultEnabled: true,
      isOptionalNoise: false,
      scanMode: .standardDirectory,
      roots: { _, home in
        [
          home.appendingPathComponent(".codeium/windsurf/skills", isDirectory: true).path,
          home.appendingPathComponent(".windsurf/skills", isDirectory: true).path,
        ]
      }
    ),
    SourceSpec(
      id: "codex-system",
      displayName: "Codex 系统内置",
      kind: .systemOrPlugin,
      defaultPriority: 2000,
      defaultEnabled: false,
      isOptionalNoise: true,
      scanMode: .recursiveSystem,
      roots: { env, home in
        var list: [String] = []
        if let codexHome = envPath("CODEX_HOME", in: env) {
          list.append(joined(codexHome, "skills/.system"))
        }
        list.append(home.appendingPathComponent(".codex/skills/.system", isDirectory: true).path)
        return list
      }
    ),
    SourceSpec(
      id: "claude-plugins",
      displayName: "Claude Code 插件技能",
      kind: .systemOrPlugin,
      defaultPriority: 2100,
      defaultEnabled: false,
      isOptionalNoise: true,
      scanMode: .claudeInstalledPlugins,
      roots: { env, home in
        var list: [String] = []
        if let claudeDir = envPath("CLAUDE_CONFIG_DIR", in: env) {
          list.append(claudeDir)
        }
        list.append(home.appendingPathComponent(".claude", isDirectory: true).path)
        return list
      }
    ),
    SourceSpec(
      id: "gemini-plugins",
      displayName: "Gemini / Antigravity 插件技能",
      kind: .systemOrPlugin,
      defaultPriority: 2200,
      defaultEnabled: false,
      isOptionalNoise: true,
      scanMode: .geminiPlugins,
      roots: { _, home in
        [
          home.appendingPathComponent(".gemini/config/plugins", isDirectory: true).path,
          home.appendingPathComponent(".gemini/antigravity/builtin/skills", isDirectory: true).path,
        ]
      }
    ),
  ]

  public static func resolvedHomeDirectory(
    environment: [String: String],
    fallback: URL
  ) -> URL {
    #if os(Windows)
      if let profile = envValue("USERPROFILE", in: environment),
        AgentPathSemantics.isAbsolute(profile, style: .windows)
      {
        return URL(fileURLWithPath: profile, isDirectory: true).standardizedFileURL
      }
      if let drive = envValue("HOMEDRIVE", in: environment),
        let path = envValue("HOMEPATH", in: environment)
      {
        let combined = drive + path
        if AgentPathSemantics.isAbsolute(combined, style: .windows) {
          return URL(fileURLWithPath: combined, isDirectory: true).standardizedFileURL
        }
      }
    #endif
    if let home = envValue("HOME", in: environment),
      AgentPathSemantics.isAbsolute(home)
    {
      return URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL
    }
    return fallback.standardizedFileURL
  }

  private static func envPath(_ name: String, in env: [String: String]) -> String? {
    guard let value = envValue(name, in: env), AgentPathSemantics.isAbsolute(value) else {
      return nil
    }
    return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL.path
  }

  private static func envValue(_ name: String, in env: [String: String]) -> String? {
    guard let key = env.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
    else { return nil }
    let value = env[key] ?? ""
    return value.isEmpty ? nil : value
  }

  private static func joined(_ base: String, _ component: String) -> String {
    URL(fileURLWithPath: base, isDirectory: true)
      .appendingPathComponent(component, isDirectory: true).standardizedFileURL.path
  }

  private static func uniquePaths(_ paths: [String], excluding excludedPath: String) -> [String] {
    var seen = Set<String>()
    #if os(Windows)
      let excludedKey = excludedPath.lowercased()
    #else
      let excludedKey = excludedPath
    #endif
    return paths.filter { path in
      #if os(Windows)
        let key = path.lowercased()
      #else
        let key = path
      #endif
      guard key != excludedKey else { return false }
      return seen.insert(key).inserted
    }
  }
}
