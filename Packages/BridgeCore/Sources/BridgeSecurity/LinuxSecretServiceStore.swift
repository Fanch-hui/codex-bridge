#if os(Linux)
  import Foundation

  public struct LinuxSecretServiceStore: SecretStore, Sendable {
    public static let defaultService = "com.openai.codex-bridge.secrets"
    public static let maximumSecretBytes = 16 * 1024

    private let service: String
    private let executableURL: URL

    public init(service: String = Self.defaultService) {
      self.init(service: service, executableURL: URL(fileURLWithPath: "/usr/bin/secret-tool"))
    }

    init(service: String, executableURL: URL) {
      precondition(!service.isEmpty && service.utf8.count <= 255)
      self.service = service
      self.executableURL = executableURL
    }

    public func store(_ secret: Data, for reference: SecretReference) throws {
      guard !secret.isEmpty, secret.count <= Self.maximumSecretBytes else {
        throw SecretStoreError.invalidSecret
      }
      _ = try run(
        arguments: ["store", "--label=Codex Bridge"] + attributes(reference),
        input: Data(secret.base64EncodedString().utf8)
      )
    }

    public func load(_ reference: SecretReference) throws -> Data {
      let result = try run(arguments: ["lookup"] + attributes(reference))
      guard let encoded = String(data: result, encoding: .utf8),
        let secret = Data(base64Encoded: encoded.trimmingCharacters(in: .newlines)),
        !secret.isEmpty, secret.count <= Self.maximumSecretBytes
      else { throw SecretStoreError.invalidStoredValue }
      return secret
    }

    public func remove(_ reference: SecretReference) throws {
      do {
        _ = try run(arguments: ["clear"] + attributes(reference))
      } catch SecretStoreError.notFound {}
    }

    private func attributes(_ reference: SecretReference) -> [String] {
      ["service", service, "reference", reference.rawValue]
    }

    private func run(arguments: [String], input: Data? = nil) throws -> Data {
      guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
        throw SecretStoreError.accessDenied
      }
      let process = Process()
      let output = Pipe()
      let error = Pipe()
      let standardInput = Pipe()
      process.executableURL = executableURL
      process.arguments = arguments
      process.standardOutput = output
      process.standardError = error
      process.standardInput = standardInput
      do {
        try process.run()
        if let input { try standardInput.fileHandleForWriting.write(contentsOf: input) }
        try standardInput.fileHandleForWriting.close()
      } catch {
        if process.isRunning { process.terminate() }
        throw SecretStoreError.accessDenied
      }
      let result = output.fileHandleForReading.readDataToEndOfFile()
      let errors = error.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        if process.terminationStatus == 1, result.isEmpty, errors.isEmpty {
          throw SecretStoreError.notFound
        }
        throw SecretStoreError.accessDenied
      }
      return result
    }
  }
#endif
