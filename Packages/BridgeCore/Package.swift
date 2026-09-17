// swift-tools-version: 6.1
import Foundation
import PackageDescription

var macOSOnlyProducts: [Product] = []
var macOSOnlyTargets: [Target] = []
var windowsApplicationLinkerFlags = [
  "-Xlinker", "/SUBSYSTEM:WINDOWS",
  "-Xlinker", "/ENTRY:mainCRTStartup",
  "-Xlinker", "/MANIFEST:EMBED",
  "-Xlinker", "/MANIFESTINPUT:Windows/CodexBridgeWindowsApp.manifest",
]
#if os(Windows)
  if let resourcePath = ProcessInfo.processInfo.environment["CODEX_BRIDGE_WINDOWS_RESOURCE"],
    !resourcePath.isEmpty
  {
    windowsApplicationLinkerFlags += ["-Xlinker", resourcePath]
  }
#endif

#if !os(Windows)
  macOSOnlyProducts = [.library(name: "BridgeServiceAppShell", targets: ["BridgeServiceAppShell"])]
  macOSOnlyTargets = [
    .target(
      name: "BridgeServiceAppShell",
      dependencies: ["BridgeDesktopUI", "BridgeIPC", "BridgeMCP", "BridgeServiceAppCore"])
  ]
#endif

let package = Package(
  name: "BridgeCore",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "BridgeDesktopUI", targets: ["BridgeDesktopUI"]),
    .library(name: "BridgeDomain", targets: ["BridgeDomain"]),
    .library(name: "BridgeSecurity", targets: ["BridgeSecurity"]),
    .library(name: "BridgeCodexRPC", targets: ["BridgeCodexRPC"]),
    .library(name: "BridgeProjects", targets: ["BridgeProjects"]),
    .library(name: "BridgeGit", targets: ["BridgeGit"]),
    .library(name: "BridgeFiles", targets: ["BridgeFiles"]),
    .library(name: "BridgeMCP", targets: ["BridgeMCP"]),
    .library(name: "BridgeTunnel", targets: ["BridgeTunnel"]),
    .library(name: "BridgeServiceCore", targets: ["BridgeServiceCore"]),
    .library(name: "BridgeSkills", targets: ["BridgeSkills"]),
    .library(name: "BridgeLegacyImport", targets: ["BridgeLegacyImport"]),
    .library(name: "BridgeCodexService", targets: ["BridgeCodexService"]),
    .library(name: "BridgeAgentCore", targets: ["BridgeAgentCore"]),
    .library(name: "BridgeOpenCodeACP", targets: ["BridgeOpenCodeACP"]),
    .library(name: "BridgeDeepSeekHarnessACP", targets: ["BridgeDeepSeekHarnessACP"]),
    .library(name: "BridgeAntigravityCLI", targets: ["BridgeAntigravityCLI"]),
    .library(name: "BridgeProcess", targets: ["BridgeProcess"]),
    .library(name: "BridgeServiceApplication", targets: ["BridgeServiceApplication"]),
    .library(name: "BridgeDirectCommand", targets: ["BridgeDirectCommand"]),
    .library(name: "BridgeIPC", targets: ["BridgeIPC"]),
    .library(name: "BridgeServiceHost", targets: ["BridgeServiceHost"]),
    .library(name: "BridgeServiceAppCore", targets: ["BridgeServiceAppCore"]),
    .library(name: "BridgeWindowsShell", targets: ["BridgeWindowsShell"]),
    .executable(name: "codex-bridge-service", targets: ["CodexBridgeServiceExecutable"]),
    .executable(
      name: "codex-bridge-windows-app",
      targets: ["CodexBridgeWindowsApp"]
    ),

  ] + macOSOnlyProducts,
  dependencies: [
    // Vendored MCP swift-sdk 0.12.1: upstream excludes the EventSource
    // dependency on Windows while importing it unconditionally, which breaks
    // windows builds; the vendored copy guards the import. Revisit when
    // upstream ships Windows support.
    .package(path: "../../Vendor/swift-sdk"),
    .package(
      url: "https://github.com/groue/GRDB.swift.git",
      exact: "7.11.1"
    ),
    .package(
      url: "https://github.com/apple/swift-log.git",
      exact: "1.15.0"
    ),
    // Upstream 2.101.3 plus one Windows-only wakeup change. Windows package
    // identities and shutdown paths require a loopback TCP pair instead of
    // the upstream AF_UNIX pair. Drop the fork after upstream ships it.
    .package(
      url: "https://github.com/yeyuancc0-glitch/swift-nio.git",
      revision: "1a69138cb7f2e63de709c9716e0348ffd6522ac7"
    ),
    .package(
      url: "https://github.com/apple/swift-crypto.git",
      exact: "3.12.0"
    ),
  ],
  targets: [
    .target(
      name: "BridgeDesktopUI",
      dependencies: ["BridgeServiceAppCore"],
      resources: [.process("Resources")]
    ),
    .target(name: "BridgeDomain"),
    .target(
      name: "BridgeSecurity",
      dependencies: [
        "BridgeAgentCore",
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .target(
      name: "BridgeCodexRPC",
      dependencies: ["BridgeAgentCore", "BridgeProcess", "BridgeSecurity"]
    ),
    .target(
      name: "BridgeProjects",
      dependencies: ["BridgeAgentCore", "BridgeDomain", "BridgeSecurity"]
    ),
    .target(
      name: "BridgeGit",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto")
      ]
    ),
    .target(
      name: "BridgeFiles",
      dependencies: [
        "BridgeAgentCore",
        "BridgeDomain",
        "BridgeGit",
        "BridgeSecurity",
        "BridgeProjects",
      ]
    ),
    .target(
      name: "BridgeMCP",
      dependencies: [
        "BridgeDomain",
        "BridgeFiles",
        "BridgeSkills",
        "BridgeSecurity",
        .product(name: "Logging", package: "swift-log"),
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ]
    ),
    .target(
      name: "BridgeTunnel",
      dependencies: [
        "BridgeSecurity",
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .target(
      name: "BridgeServiceCore",
      dependencies: [
        "BridgeAgentCore",
        "BridgeDomain",
        "BridgeProjects",
        "BridgeSecurity",
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .target(
      name: "BridgeSkills",
      dependencies: ["BridgeAgentCore", "BridgeSecurity"]
    ),
    .target(
      name: "BridgeLegacyImport",
      dependencies: [
        "BridgeDomain",
        "BridgeProjects",
        "BridgeServiceCore",
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .target(
      name: "BridgeCodexService",
      dependencies: [
        "BridgeAgentCore",
        "BridgeCodexRPC",
        "BridgeDomain",
        "BridgeProjects",
        "BridgeSecurity",
        "BridgeServiceCore",
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .target(
      name: "BridgeAgentCore",
      dependencies: ["BridgeDomain"]
    ),
    .target(
      name: "BridgeACP",
      dependencies: ["BridgeProcess"]
    ),
    .target(
      name: "BridgeOpenCodeACP",
      dependencies: [
        "BridgeACP",
        "BridgeAgentCore",
        "BridgeDomain",
        "BridgeProcess",
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .target(
      name: "BridgeDeepSeekHarnessACP",
      dependencies: [
        "BridgeACP",
        "BridgeAgentCore",
        "BridgeDomain",
        "BridgeProcess",
        "BridgeSecurity",
        .product(name: "Crypto", package: "swift-crypto"),
      ],
      resources: [.process("Resources")]
    ),
    .target(
      name: "BridgeAntigravityCLI",
      dependencies: [
        "BridgeAgentCore",
        "BridgeDomain",
        "BridgeProcess",
        "BridgeSecurity",
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .target(
      name: "BridgeServiceApplication",
      dependencies: [
        "BridgeAgentCore",
        "BridgeCodexRPC",
        "BridgeCodexService",
        "BridgeDirectCommand",
        "BridgeDomain",
        "BridgeFiles",
        "BridgeMCP",
        "BridgeProjects",
        "BridgeSecurity",
        "BridgeServiceCore",
        "BridgeSkills",
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .target(name: "BridgeProcess"),
    .target(
      name: "BridgeDirectCommand",
      dependencies: [
        "BridgeAgentCore",
        "BridgeDomain",
        "BridgeProcess",
        "BridgeProjects",
        "BridgeSecurity",
        "BridgeServiceCore",
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .target(
      name: "BridgeIPC",
      dependencies: ["BridgeMCP"]
    ),
    .target(
      name: "BridgeServiceHost",
      dependencies: [
        "BridgeAgentCore",
        "BridgeAntigravityCLI",
        "BridgeCodexRPC",
        "BridgeCodexService",
        "BridgeDirectCommand",
        "BridgeDomain",
        "BridgeDeepSeekHarnessACP",
        "BridgeLegacyImport",
        "BridgeIPC",
        "BridgeMCP",
        "BridgeOpenCodeACP",
        "BridgeProjects",
        "BridgeSecurity",
        "BridgeServiceApplication",
        "BridgeServiceCore",
        "BridgeTunnel",
      ]
    ),
    .target(
      name: "BridgeServiceAppCore",
      dependencies: [
        "BridgeIPC",
        "BridgeMCP",
      ]
    ),
    .target(
      name: "BridgeWindowsShell",
      dependencies: [
        "BridgeDesktopUI",
        "BridgeIPC",
        "BridgeMCP",
        "BridgeServiceAppCore",
      ]
    ),
    .executableTarget(
      name: "CodexBridgeServiceExecutable",
      dependencies: ["BridgeServiceHost"]
    ),
    .executableTarget(
      name: "CodexBridgeWindowsApp",
      dependencies: [
        "BridgeWindowsShell",
        "BridgeIPC",
      ],
      linkerSettings: [
        .unsafeFlags(
          windowsApplicationLinkerFlags,
          .when(platforms: [.windows])
        )
      ]
    ),

  ] + macOSOnlyTargets
)
