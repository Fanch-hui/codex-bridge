import BridgeAgentCore
import BridgeDeepSeekHarnessDesktop
import BridgeSecurity
import BridgeServiceCore
import Foundation

enum ServiceDeepSeekDesktopAssembly {
  static func make(
    paths: ServiceDataPaths, store: SimpleServiceStore,
    projects: ServiceProjectService, settings: ServiceSettings,
    secretStore: any SecretStore, installer: ServiceDeepSeekDesktopInstallation
  ) throws
    -> DeepSeekHarnessDesktopProvider
  {
    let identity = ServiceDeepSeekDesktopIdentity(store: secretStore, dataRoot: paths.rootURL)
    return try DeepSeekHarnessDesktopProvider(
      configuration: .init(
        descriptorPathProvider: { installer.descriptorPath(for: $0) },
        identityProvider: { try await identity.privateKey() },
        trustProvider: { installationID in
          guard
            let trust = try await settings.deepSeekHarnessDesktopTrust(
              installationID: installationID)
          else { return nil }
          return DeepSeekHarnessDesktopTrust(profileID: trust.profileID, publicKey: trust.publicKey)
        },
        saveTrust: { installationID, trust in
          try await settings.setDeepSeekHarnessDesktopTrust(
            trust.map {
              ServiceDeepSeekDesktopTrust(profileID: $0.profileID, publicKey: $0.publicKey)
            }, installationID: installationID)
        },
        indexLookup: { scope, profileID, sessionID in
          if try await store.isDeepSeekDesktopSessionIndexed(
            scope: scope, sessionID: sessionID, profileID: profileID)
          {
            return true
          }
          let namespace = installer.namespaceID(for: scope.installationID)
          guard namespace != scope.installationID else { return false }
          let previous = try AgentNativeSessionDirectoryScope(
            providerID: .deepSeekHarness, installationID: namespace,
            projectID: scope.projectID, projectRoot: scope.projectRoot, region: scope.region)
          return try await store.isDeepSeekDesktopSessionIndexed(
            scope: previous, sessionID: sessionID, profileID: profileID)
        },
        indexSave: { scope, profileID, sessionID in
          try await store.indexDeepSeekDesktopSession(
            scope: scope,
            sessionID: sessionID, profileID: profileID)
        },
        registeredProjectPaths: {
          try await projects.projects().map { project in
            try project.root.validateCurrentIdentity()
            return project.root.canonicalPath
          }
        },
        desktopRunning: { try await installer.desktopRunning($0) },
        installConnector: { installation in
          try await installer.install(installation)
          return DeepSeekHarnessDesktopStatus(
            connected: false, paired: false,
            unavailableReason: "连接器已安装，请启动 DSH Desktop 并完成配对。")
        }), providerID: .deepSeekHarnessDesktop)
  }
}
