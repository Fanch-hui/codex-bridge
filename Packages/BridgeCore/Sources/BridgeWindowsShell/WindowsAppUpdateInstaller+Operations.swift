#if os(Windows)
  import BridgeServiceAppCore
  import Foundation
  import WinSDK

  extension WindowsAppUpdateInstaller {
    func launchInstaller(
      packageURL: URL,
      updateDirectory: URL,
      release: AppUpdateRelease
    ) async throws {
      guard
        let directory = applicationDirectory(),
        fileManager.fileExists(atPath: directory.path)
      else {
        throw WindowsAppUpdateInstallerError.installationDirectoryUnavailable
      }
      let arguments = [
        "/VERYSILENT",
        "/SUPPRESSMSGBOXES",
        "/NORESTART",
        "/UPDATE",
        "/DIR=\(directory.path)",
      ]
      do {
        let installerProcessID = try WindowsAppUpdateProcessLauncher.launch(
          executable: packageURL.path,
          arguments: arguments,
          workingDirectory: directory.path
        )
        try await launchInstallerCleanup(
          updateDirectory: updateDirectory,
          installerProcessID: installerProcessID,
          release: release,
          applicationDirectory: directory
        )
      } catch let error as WindowsAppUpdateProcessError {
        throw WindowsAppUpdateInstallerError.installerLaunchFailed(error.code)
      }
      WindowsUIThread.shared.enqueue {
        WindowsMainWindowLifecycle.requestExit(WindowsMainWindow.currentWindow())
      }
    }

    func launchPortableHelper(updateDirectory: URL) async throws {
      guard
        Self.currentExecutablePath() != nil,
        let directory = applicationDirectory(),
        let packageURL
      else {
        throw WindowsAppUpdateInstallerError.currentExecutableUnavailable
      }
      let configuration = makePortableConfiguration(
        packageURL: packageURL,
        updateDirectory: updateDirectory
      )
      try await runHelper(configuration: configuration, arguments: [])
      WindowsUIThread.shared.enqueue {
        WindowsMainWindowLifecycle.requestExit(WindowsMainWindow.currentWindow())
      }
    }

    func preparePortablePackage(
      packageURL: URL,
      updateDirectory: URL
    ) async throws {
      let configuration = makePortableConfiguration(
        packageURL: packageURL,
        updateDirectory: updateDirectory
      )
      try await runHelper(
        configuration: configuration,
        arguments: ["-Prepare"],
        waitTimeoutMilliseconds: 120_000
      )
    }

    private func launchInstallerCleanup(
      updateDirectory: URL,
      installerProcessID: DWORD,
      release: AppUpdateRelease,
      applicationDirectory: URL
    ) async throws {
      let configuration = WindowsPortableUpdateConfiguration(
        packagePath: packageURL?.path ?? "",
        applicationDirectory: applicationDirectory.path,
        applicationExecutable: applicationDirectory.appendingPathComponent(
          Self.applicationExecutableName
        ).path,
        serviceExecutable: applicationDirectory.appendingPathComponent(Self.serviceExecutableName)
          .path,
        processID: GetCurrentProcessId(),
        payloadManifest: "SHA256SUMS.txt",
        helperScript: updateDirectory.appendingPathComponent("CodexBridgePortableUpdate.ps1").path,
        configurationPath: updateDirectory.appendingPathComponent("update.json").path,
        stagingPath: nil,
        installerProcessID: installerProcessID,
        expectedVersion: release.manifest.version,
        failureReceiptPath: failureReceiptPath(in: updateDirectory)
      )
      try await runHelper(configuration: configuration, arguments: ["-InstallerCleanup"])
    }

    private func makePortableConfiguration(
      packageURL: URL,
      updateDirectory: URL
    ) -> WindowsPortableUpdateConfiguration {
      let directory = applicationDirectory()?.path ?? ""
      let executable = Self.currentExecutablePath() ?? ""
      return WindowsPortableUpdateConfiguration(
        packagePath: packageURL.path,
        applicationDirectory: directory,
        applicationExecutable: executable,
        serviceExecutable: URL(fileURLWithPath: directory)
          .appendingPathComponent(Self.serviceExecutableName).path,
        processID: GetCurrentProcessId(),
        payloadManifest: "SHA256SUMS.txt",
        helperScript: updateDirectory.appendingPathComponent("CodexBridgePortableUpdate.ps1").path,
        configurationPath: updateDirectory.appendingPathComponent("update.json").path,
        stagingPath: updateDirectory.appendingPathComponent("staging").path,
        installerProcessID: nil,
        expectedVersion: nil,
        failureReceiptPath: failureReceiptPath(in: updateDirectory)
      )
    }

    private func runHelper(
      configuration: WindowsPortableUpdateConfiguration,
      arguments: [String],
      waitTimeoutMilliseconds: DWORD? = nil
    ) async throws {
      let configurationURL = URL(fileURLWithPath: configuration.configurationPath)
      let scriptURL = URL(fileURLWithPath: configuration.helperScript)
      do {
        try JSONEncoder().encode(configuration).write(to: configurationURL, options: .atomic)
        try WindowsPortableUpdateHelper.writeScript(to: scriptURL)
        let powerShellPath = WindowsPortableUpdateHelper.powerShellPath
        let allArguments =
          [
            "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", scriptURL.path, "-Config", configurationURL.path,
          ] + arguments
        try await Task.detached(priority: .utility) {
          _ = try WindowsAppUpdateProcessLauncher.launch(
            executable: powerShellPath,
            arguments: allArguments,
            workingDirectory: configuration.applicationDirectory,
            waitTimeoutMilliseconds: waitTimeoutMilliseconds
          )
        }.value
      } catch let error as WindowsAppUpdateProcessError {
        throw WindowsAppUpdateInstallerError.helperLaunchFailed(error.code)
      } catch {
        throw WindowsAppUpdateInstallerError.packageUnavailable
      }
    }

    private func failureReceiptPath(in _: URL) -> String {
      Self.failureReceiptURL.path
    }
  }
#endif
