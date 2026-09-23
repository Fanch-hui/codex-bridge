#if os(Windows)
  import Foundation
  import XCTest

  @testable import BridgeCodexRPC

  final class CodexExecutableResolverTests: XCTestCase {
    func testPathCmdResolvesToNativeExecutableOnly() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let npmDirectory = fixture.path("AppData", "Roaming", "npm")
      let packageRoot = fixture.path(
        "AppData",
        "Roaming",
        "npm",
        "node_modules",
        "@openai",
        "codex"
      )
      let native = try fixture.makeNativeExecutable(
        packageRoot: packageRoot, architecture: .current)
      try fixture.write("@echo off\r\n", to: fixture.path("AppData", "Roaming", "npm", "codex.cmd"))

      let resolver = CodexExecutableResolver(
        packagedInstallations: { [] },
        environment: fixture.environment(path: npmDirectory),
        architecture: .current
      )
      let resolved = try XCTUnwrap(resolver.resolve())

      XCTAssertEqual(CodexWindowsPath.normalize(resolved), CodexWindowsPath.normalize(native))
      XCTAssertTrue(resolved.lowercased().hasSuffix(".exe"))
      XCTAssertFalse(resolved.lowercased().hasSuffix(".cmd"))
    }

    func testExplicitCmdResolvesOnlyThroughItsKnownNativePackage() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let npmDirectory = fixture.path("AppData", "Roaming", "npm")
      let packageRoot = fixture.path(
        "AppData",
        "Roaming",
        "npm",
        "node_modules",
        "@openai",
        "codex"
      )
      let native = try fixture.makeNativeExecutable(packageRoot: packageRoot, architecture: .amd64)
      let shim = fixture.path("AppData", "Roaming", "npm", "codex.cmd")
      try fixture.write("@echo off\r\n", to: shim)

      let resolver = CodexExecutableResolver(
        packagedInstallations: { [] },
        environment: fixture.environment(path: npmDirectory),
        architecture: .amd64
      )
      let resolved = try XCTUnwrap(resolver.resolve(explicitPath: shim))

      XCTAssertEqual(CodexWindowsPath.normalize(resolved), CodexWindowsPath.normalize(native))
      XCTAssertEqual(
        resolver.resolve(explicitPath: fixture.path("tools", "arbitrary.cmd")),
        nil
      )
    }

    func testCustomAbsolutePathExecutableIsDiscovered() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let customDirectory = fixture.path("D", "Tools", "codex")
      let native = try fixture.makeDirectExecutable(
        directory: customDirectory,
        architecture: .current
      )
      let environment = fixture.environment(path: customDirectory)
      let resolver = CodexExecutableResolver(
        packagedInstallations: { [] }, environment: environment, architecture: .current)

      XCTAssertEqual(
        CodexWindowsPath.normalize(try XCTUnwrap(resolver.resolve())),
        CodexWindowsPath.normalize(native)
      )
    }

    func testPathRejectsNonPEExecutable() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let directory = fixture.path("Tools", "Codex")
      try fixture.write(
        "not a portable executable",
        to: fixture.path("Tools", "Codex", "codex.exe")
      )
      let resolver = CodexExecutableResolver(
        packagedInstallations: { [] },
        environment: fixture.environment(path: directory),
        architecture: .current
      )

      XCTAssertNil(resolver.resolve())
    }

    func testPathRejectsExecutableForAnotherArchitecture() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let directory = fixture.path("Tools", "Codex")
      _ = try fixture.makeDirectExecutable(
        directory: directory,
        architecture: .arm64
      )
      let resolver = CodexExecutableResolver(
        packagedInstallations: { [] },
        environment: fixture.environment(path: directory),
        architecture: .amd64
      )

      XCTAssertNil(resolver.resolve())
    }

    func testArm64ResolverAcceptsAmd64FallbackPackageAndBinary() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let packageRoot = fixture.path(
        "AppData",
        "Roaming",
        "npm",
        "node_modules",
        "@openai",
        "codex"
      )
      let amd64 = try fixture.makeNativeExecutable(packageRoot: packageRoot, architecture: .amd64)
      let environment = fixture.environment(path: fixture.path("AppData", "Roaming", "npm"))

      let resolver = CodexExecutableResolver(
        packagedInstallations: { [] }, environment: environment, architecture: .arm64)
      let resolved = try XCTUnwrap(resolver.resolve())

      XCTAssertEqual(CodexWindowsPath.normalize(resolved), CodexWindowsPath.normalize(amd64))
    }

    func testResolverSelectsCurrentArchitectureNativePackage() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let packageRoot = fixture.path(
        "AppData",
        "Roaming",
        "npm",
        "node_modules",
        "@openai",
        "codex"
      )
      let amd64 = try fixture.makeNativeExecutable(packageRoot: packageRoot, architecture: .amd64)
      let arm64 = try fixture.makeNativeExecutable(packageRoot: packageRoot, architecture: .arm64)
      let environment = fixture.environment(path: fixture.path("AppData", "Roaming", "npm"))

      let amd64Resolved = try XCTUnwrap(
        CodexExecutableResolver(
          packagedInstallations: { [] }, environment: environment, architecture: .amd64
        ).resolve()
      )
      let arm64Resolved = try XCTUnwrap(
        CodexExecutableResolver(
          packagedInstallations: { [] }, environment: environment, architecture: .arm64
        ).resolve()
      )

      XCTAssertEqual(CodexWindowsPath.normalize(amd64Resolved), CodexWindowsPath.normalize(amd64))
      XCTAssertEqual(CodexWindowsPath.normalize(arm64Resolved), CodexWindowsPath.normalize(arm64))
    }

    func testResolverFindsLocalAppDataInstallation() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let native = try fixture.makeDirectExecutable(
        directory: fixture.path("AppData", "Local", "Programs", "OpenAI", "Codex", "bin"),
        architecture: .current
      )
      let environment = fixture.environment(path: fixture.path("Project", "bin"))
      let resolver = CodexExecutableResolver(
        packagedInstallations: { [] }, environment: environment, architecture: .current)

      XCTAssertEqual(
        CodexWindowsPath.normalize(try XCTUnwrap(resolver.resolve())),
        CodexWindowsPath.normalize(native)
      )
    }

    func testResolverFindsUserProfileStandaloneInstallation() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let native = try fixture.makeDirectExecutable(
        directory: fixture.path("User", ".codex", "packages", "standalone", "current", "bin"),
        architecture: .current
      )
      let environment = fixture.environment(path: fixture.path("Project", "bin"))
      let resolver = CodexExecutableResolver(
        packagedInstallations: { [] }, environment: environment, architecture: .current)

      XCTAssertEqual(
        CodexWindowsPath.normalize(try XCTUnwrap(resolver.resolve())),
        CodexWindowsPath.normalize(native)
      )
    }

    func testResolverFindsUserProfilePluginAppServerInstallation() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let native = try fixture.makeDirectExecutable(
        directory: fixture.path("User", ".codex", "plugins", ".plugin-appserver"),
        architecture: .current
      )
      let environment = fixture.environment(path: fixture.path("Project", "bin"))
      let resolver = CodexExecutableResolver(
        packagedInstallations: { [] }, environment: environment, architecture: .current)

      XCTAssertEqual(
        CodexWindowsPath.normalize(try XCTUnwrap(resolver.resolve())),
        CodexWindowsPath.normalize(native)
      )
    }

    func testResolverDerivesUserProfileWhenWindowsVariablesAreMissing() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let native = try fixture.makeDirectExecutable(
        directory: fixture.path("User", ".codex", "plugins", ".plugin-appserver"),
        architecture: .current
      )
      var environment = fixture.environment(path: fixture.path("Project", "bin"))
      environment.removeValue(forKey: "USERPROFILE")
      environment.removeValue(forKey: "APPDATA")
      environment.removeValue(forKey: "LOCALAPPDATA")
      environment["HOME"] = fixture.path("User")

      let resolver = CodexExecutableResolver(
        packagedInstallations: { [] }, environment: environment, architecture: .current)

      XCTAssertEqual(
        CodexWindowsPath.normalize(try XCTUnwrap(resolver.resolve())),
        CodexWindowsPath.normalize(native)
      )
    }

    func testChildEnvironmentRestoresWindowsRuntimeVariables() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let environment = ["HOME": fixture.path("User")]
      let child = CodexWindowsPath.childEnvironment(
        configured: environment,
        source: [:]
      )

      XCTAssertEqual(
        CodexWindowsPath.normalize(child["USERPROFILE"] ?? ""),
        CodexWindowsPath.normalize(fixture.path("User"))
      )
      XCTAssertEqual(
        CodexWindowsPath.normalize(child["APPDATA"] ?? ""),
        CodexWindowsPath.normalize(fixture.path("User", "AppData", "Roaming"))
      )
      XCTAssertEqual(
        CodexWindowsPath.normalize(child["LOCALAPPDATA"] ?? ""),
        CodexWindowsPath.normalize(fixture.path("User", "AppData", "Local"))
      )
      XCTAssertFalse(child["TEMP"]?.isEmpty ?? true)
      XCTAssertFalse(child["TMP"]?.isEmpty ?? true)
    }

    func testWindowsCodexConfigurationNeverUsesPosixFallback() {
      let configuration = AppServerConfiguration.codex()
      XCTAssertNotEqual(configuration.executableURL.path, "/usr/bin/env")
    }

    func testEnvironmentDerivedPackageManagersAreSearched() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let pnpmNative = try fixture.makeNativeExecutable(
        packageRoot: fixture.path("pnpm-home", "global", "6", "node_modules", "@openai", "codex"),
        architecture: .current
      )
      let bunExecutable = try fixture.makeDirectExecutable(
        directory: fixture.path("bun", "bin"), architecture: .current)
      let cargoExecutable = try fixture.makeDirectExecutable(
        directory: fixture.path("cargo", "bin"), architecture: .current)
      let voltaExecutable = try fixture.makeDirectExecutable(
        directory: fixture.path("volta", "bin"), architecture: .current)

      let baseEnvironment = fixture.environment(path: fixture.path("empty-path"))
      XCTAssertEqual(
        try resolve(
          environment: baseEnvironment.merging(["PNPM_HOME": fixture.path("pnpm-home")]) { $1 }
        ),
        try XCTUnwrap(CodexWindowsPath.normalize(pnpmNative))
      )
      XCTAssertEqual(
        try resolve(
          environment: baseEnvironment.merging(["BUN_INSTALL": fixture.path("bun")]) { $1 }
        ),
        try XCTUnwrap(CodexWindowsPath.normalize(bunExecutable))
      )
      XCTAssertEqual(
        try resolve(
          environment: baseEnvironment.merging(["CARGO_HOME": fixture.path("cargo")]) { $1 }
        ),
        try XCTUnwrap(CodexWindowsPath.normalize(cargoExecutable))
      )
      XCTAssertEqual(
        try resolve(
          environment: baseEnvironment.merging(["VOLTA_HOME": fixture.path("volta")]) { $1 }
        ),
        try XCTUnwrap(CodexWindowsPath.normalize(voltaExecutable))
      )
    }

    func testProgramDataScoopAndVoltaDefaultsAreSearched() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let scooped = try fixture.makeDirectExecutable(
        directory: fixture.path("ProgramData", "scoop", "shims"),
        architecture: .current
      )
      let environment = fixture.environment(path: fixture.path("empty-path"))
        .merging(["ProgramData": fixture.path("ProgramData")]) { $1 }
      XCTAssertEqual(
        try resolve(environment: environment),
        try XCTUnwrap(CodexWindowsPath.normalize(scooped))
      )

      // The Volta default is listed before the ProgramData scoop entries, so it
      // is created only after the scoop assertion above.
      let voltad = try fixture.makeDirectExecutable(
        directory: fixture.path("AppData", "Local", "Volta", "bin"),
        architecture: .current
      )
      XCTAssertEqual(
        try resolve(environment: environment),
        try XCTUnwrap(CodexWindowsPath.normalize(voltad))
      )
    }

    func testConfiguredPathMustBeANativeBinaryOrCommandShim() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let native = try fixture.makeDirectExecutable(
        directory: fixture.path("custom"), architecture: .current)
      let script = fixture.path("custom", "codex.js")
      try fixture.write("codex", to: script)
      let shim = fixture.path("shims", "codex.cmd")
      try fixture.write("@echo off\r\n", to: shim)

      XCTAssertEqual(
        try XCTUnwrap(CodexWindowsPath.normalize(native)),
        try XCTUnwrap(
          AppServerConfiguration.resolveConfiguredCodexExecutable(native).flatMap(
            CodexWindowsPath.normalize))
      )
      XCTAssertEqual(
        try XCTUnwrap(CodexWindowsPath.normalize(shim)),
        try XCTUnwrap(
          AppServerConfiguration.resolveConfiguredCodexExecutable(shim).flatMap(
            CodexWindowsPath.normalize))
      )
      XCTAssertNil(AppServerConfiguration.resolveConfiguredCodexExecutable(script))
      XCTAssertNil(AppServerConfiguration.resolveConfiguredCodexExecutable("codex"))
      XCTAssertNil(AppServerConfiguration.resolveConfiguredCodexExecutable("   "))
    }

    func testConfiguredPathAcceptsQuotedClipboardForms() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let native = try fixture.makeDirectExecutable(
        directory: fixture.path("custom"), architecture: .current)
      let shim = fixture.path("shims", "codex.cmd")
      try fixture.write("@echo off\r\n", to: shim)

      XCTAssertEqual(
        try XCTUnwrap(CodexWindowsPath.normalize(native)),
        try XCTUnwrap(
          AppServerConfiguration.resolveConfiguredCodexExecutable("\"\(native)\"").flatMap(
            CodexWindowsPath.normalize))
      )
      XCTAssertEqual(
        try XCTUnwrap(CodexWindowsPath.normalize(shim)),
        try XCTUnwrap(
          AppServerConfiguration.resolveConfiguredCodexExecutable(" '\(shim)' ").flatMap(
            CodexWindowsPath.normalize))
      )
      XCTAssertNil(AppServerConfiguration.resolveConfiguredCodexExecutable("\"\""))
      XCTAssertNil(AppServerConfiguration.resolveConfiguredCodexExecutable("\"  \""))
    }

    private func resolve(environment: [String: String]) throws -> String {
      let resolver = CodexExecutableResolver(
        packagedInstallations: { [] },
        environment: environment,
        architecture: .current
      )
      let resolved = try XCTUnwrap(resolver.resolve())
      return try XCTUnwrap(CodexWindowsPath.normalize(resolved))
    }
  }

  private final class Fixture {
    let root: String

    init() throws {
      root =
        FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-resolver-" + UUID().uuidString, isDirectory: true)
        .path
      try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    func path(_ components: String...) -> String {
      var url = URL(fileURLWithPath: root, isDirectory: true)
      for (index, component) in components.enumerated() {
        url.appendPathComponent(component, isDirectory: index < components.count - 1)
      }
      return url.path
    }

    func environment(path: String) -> [String: String] {
      [
        "PATH": path,
        "APPDATA": self.path("AppData", "Roaming"),
        "LOCALAPPDATA": self.path("AppData", "Local"),
        "USERPROFILE": self.path("User"),
        "ProgramFiles": self.path("Program Files"),
        "ProgramW6432": self.path("Program Files"),
        "ProgramFiles(x86)": self.path("Program Files (x86)"),
      ]
    }

    func makeDirectExecutable(
      directory: String,
      architecture: CodexWindowsArchitecture
    ) throws -> String {
      let path = URL(fileURLWithPath: directory, isDirectory: true)
        .appendingPathComponent("codex.exe")
        .path
      try write(Self.peImage(for: architecture), to: path)
      return path
    }

    func makeNativeExecutable(
      packageRoot: String,
      architecture: CodexWindowsArchitecture
    ) throws -> String {
      let path = URL(fileURLWithPath: packageRoot, isDirectory: true)
        .appendingPathComponent("node_modules", isDirectory: true)
        .appendingPathComponent("@openai", isDirectory: true)
        .appendingPathComponent(architecture.nativePackageName, isDirectory: true)
        .appendingPathComponent("vendor", isDirectory: true)
        .appendingPathComponent(architecture.vendorTriple, isDirectory: true)
        .appendingPathComponent("bin", isDirectory: true)
        .appendingPathComponent("codex.exe")
        .path
      try write(Self.peImage(for: architecture), to: path)
      return path
    }

    func write(_ value: String, to path: String) throws {
      try write(Data(value.utf8), to: path)
    }

    func write(_ data: Data, to path: String) throws {
      try FileManager.default.createDirectory(
        atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
        withIntermediateDirectories: true
      )
      try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func remove() {
      try? FileManager.default.removeItem(atPath: root)
    }

    private static func peImage(for architecture: CodexWindowsArchitecture) -> Data {
      let machine: UInt16
      switch architecture {
      case .amd64:
        machine = 0x8664
      case .arm64:
        machine = 0xAA64
      }
      var bytes = [UInt8](repeating: 0, count: 512)
      bytes[0] = 0x4D
      bytes[1] = 0x5A
      bytes[0x3C] = 0x80
      bytes[0x80] = 0x50
      bytes[0x81] = 0x45
      bytes[0x84] = UInt8(machine & 0xFF)
      bytes[0x85] = UInt8(machine >> 8)
      bytes[0x96] = 0x02
      return Data(bytes)
    }
  }
#endif
