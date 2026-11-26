// swift-tools-version: 6.1

import Foundation
import PackageDescription

var localMCPTestDependencies: [Target.Dependency] = [
  "BridgeLocalMCP", "BridgeMCP", "BridgeIPC", .product(name: "MCP", package: "swift-sdk"),
]
#if os(macOS)
  localMCPTestDependencies += ["BridgeServiceHost", "BridgeSecurity", "BridgeCodexRPC"]
#endif


var macOSOnlyProducts: [Product] = []
var macOSOnlyTargets: [Target] = []

#if !os(Windows)
#endif

#if !os(macOS)
#endif

var linuxOnlyProducts: [Product] = []
var linuxOnlyTargets: [Target] = []
var linuxDesktopDependencies: [Target.Dependency] = []
#if os(Linux)
  linuxDesktopDependencies = ["CLinuxDesktop"]
  linuxOnlyProducts = [
    .executable(name: "codex-bridge-linux-app", targets: ["CodexBridgeLinuxApp"])
  ]
  linuxOnlyTargets = [
    .systemLibrary(
      name: "CWebKitGTK", pkgConfig: "webkit2gtk-4.1",
      providers: [.apt(["libwebkit2gtk-4.1-dev"])]
    ),
    .target(name: "CLinuxDesktop", dependencies: ["CWebKitGTK"]),
    .executableTarget(
      name: "CodexBridgeLinuxApp", dependencies: ["BridgeDesktopShell", "BridgeLocalMCP"]),
  ]
#endif

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

#if os(macOS)
  macOSOnlyProducts = [
    .library(name: "BridgeServiceAppShell", targets: ["BridgeServiceAppShell"]),
    
    
    
  ]
  macOSOnlyTargets = [
    .target(
      name: "BridgeServiceAppShell",
      dependencies: [
        "BridgeAgentCore",
        "BridgeDesktopUI",
        "BridgeIPC",
        "BridgeMCP",
        "BridgeServiceAppCore",
      ]
    ),
    
    
    
  ]
#endif

#if os(Windows)
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
    .library(name: "BridgeDeepSeekHarnessDesktop", targets: ["BridgeDeepSeekHarnessDesktop"]),
    .library(name: "BridgeEmbeddedDSH", targets: ["BridgeEmbeddedDSH"]),
    .library(name: "BridgeAntigravityCLI", targets: ["BridgeAntigravityCLI"]),
    .library(name: "BridgePiRPC", targets: ["BridgePiRPC"]),
    .library(name: "BridgeQoderSDK", targets: ["BridgeQoderSDK"]),
    .library(name: "BridgeClaudeSDK", targets: ["BridgeClaudeSDK"]),
    .library(name: "BridgeProcess", targets: ["BridgeProcess"]),
    .library(name: "BridgeServiceApplication", targets: ["BridgeServiceApplication"]),
    .library(name: "BridgeDirectCommand", targets: ["BridgeDirectCommand"]),
    .library(name: "BridgeIPC", targets: ["BridgeIPC"]),
    .library(name: "BridgeLocalMCP", targets: ["BridgeLocalMCP"]),
    .library(name: "BridgeServiceHost", targets: ["BridgeServiceHost"]),
    .library(name: "BridgeServiceAppCore", targets: ["BridgeServiceAppCore"]),
    .library(name: "BridgeWindowsShell", targets: ["BridgeWindowsShell"]),
    .library(name: "BridgeDesktopShell", targets: ["BridgeDesktopShell"]),
    .executable(name: "codex-bridge-service", targets: ["CodexBridgeServiceExecutable"]),
    .executable(
      name: "codex-bridge-windows-app",
      targets: ["CodexBridgeWindowsApp"]
    ),
    
  ] + macOSOnlyProducts + linuxOnlyProducts,
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
      dependencies: ["BridgeServiceAppCore", "BridgeAgentCore", "BridgeIPC"],
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
        "BridgeAgentCore",
        "BridgeDomain",
        "BridgeFiles",
        "BridgeSkills",
        "BridgeSecurity",
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ],
      resources: [.copy("Resources/FileTransfer")]
    ),
    .target(
      name: "BridgeTunnel",
      dependencies: [
        "BridgeProcess",
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
      dependencies: [
        "BridgeAgentCore",
        "BridgeSecurity",
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .target(
      name: "BridgeLegacyImport",
      dependencies: [
        "BridgeDomain",
        "BridgeProjects",
        "BridgeServiceCore",
        "BridgeTunnel",
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
        "BridgeProcess",
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
      dependencies: ["BridgeAgentCore", "BridgeProcess", "BridgeSecurity"]
    ),
    .target(
      name: "BridgeEmbeddedDSH",
      dependencies: [
        "BridgeACP", "BridgeAgentCore", "BridgeProcess", "BridgeSecurity",
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .target(
      name: "BridgeProviderRuntime",
      dependencies: ["BridgeACP", "BridgeSecurity", "BridgeEmbeddedDSH", "BridgeProcess"]
    ),
    .target(
      name: "BridgeModelGateway",
      dependencies: [
        "BridgeProviderRuntime", "BridgeACP", "BridgeSecurity",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOWebSocket", package: "swift-nio"),
      ]
    ),
    .target(
      name: "BridgeOpenCodeACP",
      dependencies: [
        "BridgeACP",
        "BridgeAgentCore",
        "BridgeDomain",
        "BridgeProcess",
        "BridgeSecurity",
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "GRDB", package: "GRDB.swift"),
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
      name: "BridgeDeepSeekHarnessDesktop",
      dependencies: [
        "BridgeACP", "BridgeAgentCore", "BridgeDomain", "BridgeSecurity",
        "BridgeDeepSeekHarnessACP",
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ],
      resources: [.copy("Resources/DSHDesktopConnector")]
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
    .target(name: "BridgeProcess", dependencies: ["BridgeAgentCore"]),
    .target(
      name: "BridgePiRPC",
      dependencies: ["BridgeAgentCore", "BridgeDomain", "BridgeProcess", "BridgeSecurity"],
      resources: [.copy("Resources/PiBridgeExtension"), .copy("Resources/PiNativeHistory")]
    ),
    .target(
      name: "BridgeQoderSDK",
      dependencies: ["BridgeACP", "BridgeAgentCore", "BridgeDomain", "BridgeSecurity"],
      resources: [.copy("Resources/QoderHost")]
    ),
    .target(
      name: "BridgeClaudeSDK",
      dependencies: [
        "BridgeACP", "BridgeAgentCore", "BridgeDomain", "BridgeProcess", "BridgeSecurity",
      ],
      resources: [.copy("Resources/ClaudeHost")]
    ),
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
      name: "BridgeLocalMCP",
      dependencies: [
        "BridgeIPC", "BridgeSecurity",
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    // Minimal WinHTTP interop for the Windows upstream Codex WebSocket client:
    // the toolchain's WinSDK module does not expose <winhttp.h>.
    .target(
      name: "BridgeWinHTTP",
      linkerSettings: [.linkedLibrary("winhttp", .when(platforms: [.windows]))]
    ),
    .target(
      name: "BridgeServiceGateway",
      dependencies: [
        "BridgeACP", "BridgeAgentCore", "BridgeDomain", "BridgeEmbeddedDSH", "BridgeIPC",
        "BridgeMCP", "BridgeModelGateway", "BridgeProcess", "BridgeProviderRuntime",
        "BridgeSecurity", "BridgeServiceApplication", "BridgeServiceCore",
        .product(name: "Crypto", package: "swift-crypto"),
        .target(name: "BridgeWinHTTP", condition: .when(platforms: [.windows])),
      ],
      resources: [.embedInCode("Resources/CodexBaseInstructions.md")]
    ),
    .target(
      name: "BridgeAgentSetup",
      dependencies: [
        "BridgeACP", "BridgeAgentCore", "BridgeClaudeSDK", "BridgeDeepSeekHarnessACP",
        "BridgeDeepSeekHarnessDesktop", "BridgeIPC", "BridgeOpenCodeACP", "BridgeProcess",
        "BridgeQoderSDK", "BridgeSecurity", "BridgeServiceApplication", "BridgeServiceCore",
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .target(
      name: "BridgeServiceTunnel",
      dependencies: [
        "BridgeSecurity", "BridgeServiceApplication", "BridgeServiceCore", "BridgeTunnel",
      ]
    ),
    .target(
      name: "BridgeWorkbenchService",
      dependencies: [
        "BridgeACP", "BridgeAgentCore", "BridgeCodexRPC", "BridgeCodexService",
        "BridgeDeepSeekHarnessDesktop", "BridgeDomain", "BridgeEmbeddedDSH", "BridgeFiles",
        "BridgeIPC", "BridgeMCP", "BridgeProcess", "BridgeSecurity",
        "BridgeServiceApplication", "BridgeServiceCore", "BridgeSkills", "BridgeSubagentRounds",
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .target(
      name: "BridgeSubagentRounds",
      dependencies: ["BridgeACP", "BridgeDomain", "BridgeServiceCore"]
    ),
    .target(
      name: "BridgeServiceHost",
      dependencies: [
        "BridgeAgentSetup",
        "BridgeServiceGateway",
        "BridgeServiceTunnel",
        "BridgeSubagentRounds",
        "BridgeWorkbenchService",
        "BridgeProviderRuntime", "BridgeModelGateway",
        "BridgeACP",
        "BridgeEmbeddedDSH",
        "BridgeAgentCore",
        "BridgeAntigravityCLI",
        "BridgePiRPC",
        "BridgeQoderSDK",
        "BridgeClaudeSDK",
        "BridgeCodexRPC",
        "BridgeCodexService",
        "BridgeDirectCommand",
        "BridgeDomain",
        "BridgeDeepSeekHarnessACP",
        "BridgeDeepSeekHarnessDesktop",
        "BridgeLegacyImport",
        "BridgeIPC",
        "BridgeMCP",
        "BridgeOpenCodeACP",
        "BridgeProjects",
        "BridgeProcess",
        "BridgeSecurity",
        "BridgeServiceApplication",
        "BridgeServiceCore",
        "BridgeSkills",
        "BridgeTunnel",
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .target(
      name: "BridgeServiceAppCore",
      dependencies: [
        "BridgeAgentCore",
        "BridgeIPC",
        "BridgeMCP",
        "BridgeSecurity",
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .target(
      name: "BridgeDesktopShell",
      dependencies: [
        "BridgeDesktopUI",
        "BridgeIPC",
        "BridgeMCP",
        "BridgeServiceAppCore",
      ] + linuxDesktopDependencies
    ),
    .target(name: "BridgeWindowsShell", dependencies: ["BridgeDesktopShell"]),
    .executableTarget(
      name: "CodexBridgeServiceExecutable",
      dependencies: ["BridgeServiceHost"]
    ),
    .executableTarget(
      name: "CodexBridgeWindowsApp",
      dependencies: [
        "BridgeWindowsShell",
        "BridgeIPC",
        "BridgeLocalMCP",
      ],
      linkerSettings: [
        .unsafeFlags(
          windowsApplicationLinkerFlags,
          .when(platforms: [.windows])
        )
      ]
    ),
    
  ] + macOSOnlyTargets + linuxOnlyTargets
)
