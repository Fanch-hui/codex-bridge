#if os(Windows)
  import BridgeAgentCore
  import Foundation

  enum CodexWindowsArchitecture: Sendable {
    case amd64
    case arm64

    static var current: Self {
      #if arch(arm64)
        return .arm64
      #else
        return .amd64
      #endif
    }

    var nativePackageName: String {
      switch self {
      case .amd64: "codex-win32-x64"
      case .arm64: "codex-win32-arm64"
      }
    }

    var vendorTriple: String {
      switch self {
      case .amd64: "x86_64-pc-windows-msvc"
      case .arm64: "aarch64-pc-windows-msvc"
      }
    }

    func accepts(machine: UInt16) -> Bool {
      switch self {
      case .amd64:
        machine == 0x8664
      case .arm64:
        machine == 0xAA64 || machine == 0xA641 || machine == 0x8664
      }
    }
  }

  struct CodexExecutableResolver: Sendable {
    typealias Validator = @Sendable (String, CodexWindowsArchitecture) -> Bool
    typealias RegularFileCheck = @Sendable (String) -> Bool

    private let environment: [String: String]
    private let architecture: CodexWindowsArchitecture
    private let validator: Validator
    private let regularFileCheck: RegularFileCheck
    private let packagedInstallations: @Sendable () -> [String]

    init(
      packagedInstallations: @escaping @Sendable () -> [String] =
        CodexWindowsPackageDiscovery.installationDirectories,
      environment: [String: String] = ToolDiscoveryEnvironment.current(),
      architecture: CodexWindowsArchitecture = .current,
      validator: @escaping Validator = CodexWindowsNativeExecutable.isValid,
      regularFileCheck: @escaping RegularFileCheck = CodexWindowsNativeExecutable.isRegularFile
    ) {
      self.environment = environment
      self.architecture = architecture
      self.validator = validator
      self.regularFileCheck = regularFileCheck
      self.packagedInstallations = packagedInstallations
    }

    func resolve(explicitPath: String? = nil) -> String? {
      let candidates = explicitPath.map(expandedExplicitPaths) ?? candidatePaths()
      return CodexWindowsPath.unique(candidates).first(where: {
        validator($0, architecture)
      })
    }

    private func expandedExplicitPaths(_ path: String) -> [String] {
      guard let normalized = CodexWindowsPath.normalize(path) else { return [] }
      if normalized.lowercased().hasSuffix(".exe") { return [normalized] }
      guard normalized.lowercased().hasSuffix(".cmd"),
        CodexWindowsPath.basename(normalized)?.lowercased() == "codex.cmd",
        regularFileCheck(normalized),
        let directory = CodexWindowsPath.parent(normalized)
      else {
        return []
      }
      return nativeCodexPaths(
        packageRoot: CodexWindowsPath.join(directory, "node_modules", "@openai", "codex")
      )
    }

    private func candidatePaths() -> [String] {
      let userProfile = CodexWindowsPath.userProfile(in: environment)
      let appData =
        CodexWindowsPath.environmentValue("APPDATA", in: environment)
        ?? userProfile.map { CodexWindowsPath.join($0, "AppData", "Roaming") }
      let localAppData =
        CodexWindowsPath.environmentValue("LOCALAPPDATA", in: environment)
        ?? userProfile.map { CodexWindowsPath.join($0, "AppData", "Local") }
      let programFiles = CodexWindowsPath.environmentValue("ProgramFiles", in: environment)
      let programFilesX86 = CodexWindowsPath.environmentValue("ProgramFiles(x86)", in: environment)
      let programW6432 = CodexWindowsPath.environmentValue("ProgramW6432", in: environment)
      let programData = CodexWindowsPath.environmentValue("ProgramData", in: environment)
      var result: [String] = []

      if let configured = CodexWindowsPath.environmentValue(
        "CODEX_BRIDGE_CODEX_EXECUTABLE", in: environment
      ) {
        result.append(contentsOf: expandedExplicitPaths(configured))
      }
      result.append(
        contentsOf: packagedInstallations().map {
          CodexWindowsPath.join($0, "app", "resources", "codex.exe")
        })
      appendOfficialInstallations(
        localAppData: localAppData,
        programFiles: programFiles,
        programFilesX86: programFilesX86,
        programW6432: programW6432,
        programData: programData,
        userProfile: userProfile,
        to: &result
      )
      result.append(
        contentsOf: packageExecutables(
          appData: appData,
          localAppData: localAppData,
          userProfile: userProfile
        ))
      result.append(
        contentsOf: pathExecutables(
          path: CodexWindowsPath.environmentValue("PATH", in: environment) ?? ""
        ))
      return result
    }

    private func appendOfficialInstallations(
      localAppData: String?,
      programFiles: String?,
      programFilesX86: String?,
      programW6432: String?,
      programData: String?,
      userProfile: String?,
      to result: inout [String]
    ) {
      if let localAppData {
        result.append(contentsOf: [
          CodexWindowsPath.join(localAppData, "Programs", "OpenAI", "Codex", "bin", "codex.exe"),
          CodexWindowsPath.join(localAppData, "Programs", "Codex", "bin", "codex.exe"),
          CodexWindowsPath.join(localAppData, "Programs", "Codex", "resources", "codex.exe"),
          CodexWindowsPath.join(localAppData, "Programs", "ChatGPT", "resources", "codex.exe"),
          CodexWindowsPath.join(
            localAppData, "Programs", "OpenAI", "ChatGPT", "resources", "codex.exe"),
          CodexWindowsPath.join(localAppData, "Volta", "bin", "codex.exe"),
        ])
      }
      if let userProfile {
        result.append(contentsOf: [
          CodexWindowsPath.join(
            userProfile,
            ".codex",
            "plugins",
            ".plugin-appserver",
            "codex.exe"
          ),
          CodexWindowsPath.join(
            userProfile,
            ".codex",
            ".sandbox-bin",
            "codex.exe"
          ),
          CodexWindowsPath.join(userProfile, ".codex", "bin", "codex.exe"),
          CodexWindowsPath.join(userProfile, ".codex", "codex.exe"),
          CodexWindowsPath.join(
            userProfile,
            ".codex",
            "packages",
            "standalone",
            "current",
            "bin",
            "codex.exe"
          ),
          CodexWindowsPath.join(userProfile, ".cargo", "bin", "codex.exe"),
          CodexWindowsPath.join(userProfile, ".local", "bin", "codex.exe"),
          CodexWindowsPath.join(userProfile, "scoop", "shims", "codex.exe"),
          CodexWindowsPath.join(userProfile, "scoop", "apps", "codex", "current", "codex.exe"),
        ])
      }
      if let localAppData {
        result.append(
          CodexWindowsPath.join(localAppData, "Microsoft", "WinGet", "Links", "codex.exe")
        )
      }
      if let programData {
        result.append(contentsOf: [
          CodexWindowsPath.join(programData, "scoop", "shims", "codex.exe"),
          CodexWindowsPath.join(programData, "scoop", "apps", "codex", "current", "codex.exe"),
        ])
      }
      result.append("C:\\ProgramData\\chocolatey\\bin\\codex.exe")
      for root in [programW6432, programFiles, programFilesX86].compactMap({ $0 }) {
        result.append(contentsOf: [
          CodexWindowsPath.join(root, "OpenAI", "Codex", "bin", "codex.exe"),
          CodexWindowsPath.join(root, "OpenAI", "Codex", "codex.exe"),
          CodexWindowsPath.join(root, "Codex", "bin", "codex.exe"),
          CodexWindowsPath.join(root, "Codex", "codex.exe"),
        ])
      }
    }

    private func packageExecutables(
      appData: String?,
      localAppData: String?,
      userProfile: String?
    ) -> [String] {
      var roots: [String] = []
      var result: [String] = []
      if let appData {
        let npmDirectory = CodexWindowsPath.join(appData, "npm")
        result.append(CodexWindowsPath.join(npmDirectory, "codex.exe"))
        roots.append(CodexWindowsPath.join(appData, "npm", "node_modules", "@openai", "codex"))
      }
      if let localAppData {
        let pnpmHome = CodexWindowsPath.join(localAppData, "pnpm")
        result.append(CodexWindowsPath.join(pnpmHome, "codex.exe"))
        result.append(CodexWindowsPath.join(localAppData, "Yarn", "bin", "codex.exe"))
        roots.append(contentsOf: pnpmPackageRoots(home: pnpmHome))
        roots.append(
          CodexWindowsPath.join(
            localAppData,
            "Yarn",
            "Data",
            "global",
            "node_modules",
            "@openai",
            "codex"
          ))
      }
      if let userProfile {
        result.append(
          CodexWindowsPath.join(
            userProfile,
            ".bun",
            "bin",
            "codex.exe"
          ))
        roots.append(
          CodexWindowsPath.join(
            userProfile,
            ".bun",
            "install",
            "global",
            "node_modules",
            "@openai",
            "codex"
          ))
      }
      // Package managers can relocate their global prefixes through the
      // environment, so the reflected values must be searched as well.
      if let prefix = CodexWindowsPath.environmentValue("NPM_CONFIG_PREFIX", in: environment) {
        result.append(CodexWindowsPath.join(prefix, "codex.exe"))
        roots.append(CodexWindowsPath.join(prefix, "node_modules", "@openai", "codex"))
      }
      if let pnpmHome = CodexWindowsPath.environmentValue("PNPM_HOME", in: environment) {
        result.append(CodexWindowsPath.join(pnpmHome, "codex.exe"))
        roots.append(contentsOf: pnpmPackageRoots(home: pnpmHome))
      }
      if let bunRoot = CodexWindowsPath.environmentValue("BUN_INSTALL", in: environment) {
        result.append(CodexWindowsPath.join(bunRoot, "bin", "codex.exe"))
        roots.append(
          CodexWindowsPath.join(
            bunRoot, "install", "global", "node_modules", "@openai", "codex"))
      }
      if let cargoHome = CodexWindowsPath.environmentValue("CARGO_HOME", in: environment) {
        result.append(CodexWindowsPath.join(cargoHome, "bin", "codex.exe"))
      }
      if let voltaHome = CodexWindowsPath.environmentValue("VOLTA_HOME", in: environment) {
        result.append(CodexWindowsPath.join(voltaHome, "bin", "codex.exe"))
      }
      result.append(contentsOf: roots.flatMap { nativeCodexPaths(packageRoot: $0) })
      return result
    }

    /// pnpm keeps global packages beside its shim directory instead of inside it.
    private func pnpmPackageRoots(home: String) -> [String] {
      (5...10).map { version in
        CodexWindowsPath.join(
          home,
          "global",
          String(version),
          "node_modules",
          "@openai",
          "codex"
        )
      }
    }

    private func pathExecutables(path: String) -> [String] {
      CodexWindowsPath.splitSearchPath(path).flatMap { directory in
        var result = [CodexWindowsPath.join(directory, "codex.exe")]
        let hasCommandShim = ["codex.cmd", "codex.bat"]
          .map { CodexWindowsPath.join(directory, $0) }
          .contains(where: regularFileCheck)
        guard hasCommandShim else { return result }
        let packageRoot = CodexWindowsPath.join(directory, "node_modules", "@openai", "codex")
        result.append(contentsOf: nativeCodexPaths(packageRoot: packageRoot))
        if let parent = CodexWindowsPath.parent(directory) {
          result.append(
            contentsOf: nativeCodexPaths(
              packageRoot: CodexWindowsPath.join(parent, "node_modules", "@openai", "codex")
            ))
        }
        return result
      }
    }

    private func nativeCodexPaths(packageRoot: String) -> [String] {
      let architectures: [CodexWindowsArchitecture] = {
        switch architecture {
        case .amd64: [.amd64]
        case .arm64: [.arm64, .amd64]
        }
      }()
      return architectures.flatMap { arch in
        let nativeRoot = CodexWindowsPath.join(
          packageRoot,
          "node_modules",
          "@openai",
          arch.nativePackageName
        )
        let siblingRoot = CodexWindowsPath.parent(packageRoot).map {
          CodexWindowsPath.join($0, arch.nativePackageName)
        }
        return [
          CodexWindowsPath.join(nativeRoot, "vendor", arch.vendorTriple, "bin", "codex.exe"),
          siblingRoot.map {
            CodexWindowsPath.join($0, "vendor", arch.vendorTriple, "bin", "codex.exe")
          },
          CodexWindowsPath.join(packageRoot, "vendor", arch.vendorTriple, "bin", "codex.exe"),
        ].compactMap { $0 }
      }
    }
  }
#endif
