import Foundation

enum BoundedProcessLauncher {
  static func validate(_ configuration: BoundedProcessConfiguration) throws {
    #if os(Windows)
      // On Windows the executable may be resolved through PATH (for example
      // "git"), so it is not required to be an existing file URL here.
      let strings =
        [configuration.executableURL.path, configuration.workingDirectory.url.path]
        + configuration.arguments + configuration.environment
      guard
        configuration.workingDirectory.url.isFileURL,
        configuration.maximumStandardOutputBytes > 0,
        configuration.maximumStandardErrorBytes > 0,
        strings.allSatisfy({ !$0.contains("\0") })
      else {
        throw BoundedProcessError.invalidConfiguration
      }
    #else
      let strings =
        [configuration.executableURL.path, configuration.workingDirectory.url.path]
        + configuration.arguments + configuration.environment
      guard
        configuration.executableURL.isFileURL,
        configuration.workingDirectory.url.isFileURL,
        configuration.maximumStandardOutputBytes > 0,
        configuration.maximumStandardErrorBytes > 0,
        strings.allSatisfy({ !$0.contains("\0") })
      else {
        throw BoundedProcessError.invalidConfiguration
      }
    #endif
  }
}
