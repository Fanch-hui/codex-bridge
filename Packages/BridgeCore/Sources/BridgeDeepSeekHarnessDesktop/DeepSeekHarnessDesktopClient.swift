import BridgeACP
import BridgeAgentCore
import Foundation

public struct DeepSeekHarnessDesktopRPCError: Error, LocalizedError, Equatable, Sendable {
  public let code: String
  public let message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }

  public var errorDescription: String? { message }
}

public actor DeepSeekHarnessDesktopClient {
  public let descriptor: DeepSeekHarnessDesktopDescriptor
  private let transport: any DeepSeekHarnessDesktopTransport
  private let signing: DesktopSigning
  private let transcriptHash: String
  private let timeout: Duration
  private var sentSequence: Int64 = 0
  private var receivedSequence: Int64 = 0
  private var pending: [String: CheckedContinuation<ACPJSONValue, any Error>] = [:]
  private var readTask: Task<Void, Never>?
  private var writeTask: Task<Void, Never>?
  private var closed = false

  public var isOpen: Bool { !closed }

  private init(
    descriptor: DeepSeekHarnessDesktopDescriptor, transport: any DeepSeekHarnessDesktopTransport,
    signing: DesktopSigning, transcriptHash: String, timeout: Duration
  ) {
    self.descriptor = descriptor
    self.transport = transport
    self.signing = signing
    self.transcriptHash = transcriptHash
    self.timeout = timeout
  }

  public static func connect(
    descriptor: DeepSeekHarnessDesktopDescriptor, identity: Data,
    trust: DeepSeekHarnessDesktopTrust?, timeout: Duration = .seconds(30),
    transportFactory: DeepSeekHarnessDesktopTransportFactory
  ) async throws -> DeepSeekHarnessDesktopClient {
    if let trust {
      guard trust.profileID == descriptor.profileID, trust.publicKey == descriptor.publicKey else {
        throw AgentRuntimeError.unsupportedProtocol("dsh_desktop_profile_changed")
      }
    }
    let transport = try await transportFactory(descriptor.port)
    do {
      let signing = try DesktopSigning(identity: identity)
      let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
      try await transport.send(
        ACPJSONValue.object([
          "type": .string("hello"), "protocol": .string(DesktopSigning.protocolRevision),
          "publicKey": .string(signing.publicKey), "clientNonce": .string(nonce),
        ]).encodedData())
      let challenge = try await receiveHandshake(transport, timeout: timeout)
      guard challenge["type"]?.stringValue == "challenge",
        challenge["protocol"]?.stringValue == DesktopSigning.protocolRevision,
        challenge["clientNonce"]?.stringValue == nonce,
        challenge["publicKey"]?.stringValue == descriptor.publicKey,
        challenge["profileID"]?.stringValue == descriptor.profileID,
        challenge["instanceID"]?.stringValue == descriptor.instanceID,
        let serverNonce = challenge["serverNonce"]?.stringValue,
        Data(base64Encoded: serverNonce)?.count == 32,
        let signature = challenge["signature"]?.stringValue
      else { throw AgentRuntimeError.unsupportedProtocol("dsh_desktop_challenge") }
      let transcript = DesktopSigning.transcript(
        clientKey: signing.publicKey, serverKey: descriptor.publicKey, clientNonce: nonce,
        serverNonce: serverNonce, profileID: descriptor.profileID, instanceID: descriptor.instanceID
      )
      try DesktopSigning.verify(signature, data: transcript, publicKey: descriptor.publicKey)
      try await transport.send(
        ACPJSONValue.object([
          "type": .string("auth"), "signature": .string(try signing.signature(transcript)),
        ]).encodedData())
      let client = Self(
        descriptor: descriptor, transport: transport, signing: signing,
        transcriptHash: DesktopSigning.digest(transcript), timeout: timeout)
      await client.startReading()
      return client
    } catch {
      await transport.close()
      throw error
    }
  }

  public func call(_ method: String, params: [String: ACPJSONValue] = [:]) async throws
    -> ACPJSONValue
  {
    guard !closed else { throw AgentRuntimeError.processUnavailable }
    let id = UUID().uuidString
    let payload: ACPJSONValue = .object([
      "id": .string(id), "method": .string(method), "params": .object(params),
    ])
    sentSequence += 1
    let frame = try signing.frame(
      payload: payload, sequence: sentSequence,
      transcriptHash: transcriptHash
    ).encodedData()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pending[id] = continuation
        let previous = writeTask
        writeTask = Task {
          await previous?.value
          do { try await transport.send(frame) } catch { failRequest(id, error: error) }
        }
        Task {
          try? await Task.sleep(for: timeout)
          failRequest(id, error: AgentRuntimeError.timedOut)
        }
      }
    } onCancel: {
      Task { await self.failRequest(id, error: CancellationError()) }
    }
  }

  public func close() async {
    readTask?.cancel()
    await transport.close()
    failAll(AgentRuntimeError.processUnavailable)
  }

  private func startReading() {
    readTask = Task { [weak self, transport] in
      do {
        while !Task.isCancelled {
          let bytes = try await transport.receive()
          try await self?.received(bytes)
        }
      } catch { await self?.failAll(error) }
    }
  }

  private func received(_ bytes: Data) throws {
    let frame = try JSONDecoder().decode(ACPJSONValue.self, from: bytes)
    let payload = try DesktopSigning.payload(
      frame, expectedSequence: receivedSequence + 1,
      transcriptHash: transcriptHash, publicKey: descriptor.publicKey)
    receivedSequence += 1
    guard let id = payload["id"]?.stringValue, let continuation = pending.removeValue(forKey: id)
    else { return }
    if let error = payload["error"] {
      continuation.resume(
        throwing: DeepSeekHarnessDesktopRPCError(
          code: error["code"]?.stringValue ?? "native_runtime_error",
          message: error["message"]?.stringValue ?? "DSH Desktop operation failed."))
    } else if let result = payload["result"] {
      continuation.resume(returning: result)
    } else {
      continuation.resume(throwing: AgentRuntimeError.malformedEvent("dsh_desktop_reply"))
    }
  }

  private func failRequest(_ id: String, error: any Error) {
    pending.removeValue(forKey: id)?.resume(throwing: error)
  }

  private func failAll(_ error: any Error) {
    closed = true
    let values = pending.values
    pending.removeAll()
    for continuation in values { continuation.resume(throwing: error) }
  }

  private static func receiveHandshake(
    _ transport: any DeepSeekHarnessDesktopTransport,
    timeout: Duration
  ) async throws -> ACPJSONValue {
    try await withThrowingTaskGroup(of: ACPJSONValue.self) { group in
      group.addTask {
        let data = try await transport.receive()
        return try JSONDecoder().decode(ACPJSONValue.self, from: data)
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        await transport.close()
        throw AgentRuntimeError.timedOut
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else { throw AgentRuntimeError.processUnavailable }
      return result
    }
  }
}
