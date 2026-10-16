import Foundation
import MCP

actor MCPStdioProxy {
  private let stdio: any Transport
  private let upstream: HTTPClientTransport
  private let connection: LocalMCPConnection
  private var initializationID: Envelope.ID?
  private var disconnectTask: Task<Void, Never>?
  private var failure: (any Error)?

  init(stdio: any Transport, connection: LocalMCPConnection) {
    self.stdio = stdio
    self.connection = connection
    upstream = connection.transport()
  }

  func run() async throws {
    do {
      try await upstream.connect()
      try await stdio.connect()
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await self.forwardInput() }
        group.addTask { try await self.forwardOutput() }
        do {
          _ = try await group.next()
        } catch {
          await self.disconnect()
          group.cancelAll()
          throw error
        }
        await disconnect()
        group.cancelAll()
      }
      if let failure { throw failure }
    } catch {
      await disconnect()
      throw error
    }
  }

  private func forwardInput() async throws {
    try await withThrowingTaskGroup(of: Void.self) { requests in
      var pending = 0
      for try await message in await stdio.receive() {
        let envelope = try JSONDecoder().decode(Envelope.self, from: message)
        if envelope.method == "initialize" {
          initializationID = envelope.id
          try await upstream.send(message)
        } else if envelope.id == nil {
          try await upstream.send(message)
        } else {
          requests.addTask {
            do {
              try await self.upstream.send(message)
            } catch {
              await self.recordFailure(error)
              throw error
            }
          }
          pending += 1
          if pending >= 32 {
            _ = try await requests.next()
            pending -= 1
          }
        }
      }
      await disconnect()
      requests.cancelAll()
    }
  }

  private func forwardOutput() async throws {
    for try await response in await upstream.receive() {
      for message in try Self.responseMessages(response) {
        let envelope = try JSONDecoder().decode(Envelope.self, from: message)
        if let version = envelope.result?.protocolVersion,
          envelope.id != nil, envelope.id == initializationID
        {
          await upstream.updateNegotiatedProtocolVersion(version)
        }
        try await stdio.send(message.filter { $0 != 10 && $0 != 13 })
      }
    }
  }

  nonisolated static func responseMessages(_ response: Data) throws -> [Data] {
    guard let text = String(data: response, encoding: .utf8) else {
      throw MCPError.parseError("Invalid MCP response encoding")
    }
    if text.first(where: { !$0.isWhitespace }) == "{" { return [response] }
    // The SDK returns complete, unparsed POST SSE bodies on Linux.
    var messages: [Data] = []
    var fields: [Substring] = []
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    for line in lines.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.isEmpty {
        let message = fields.joined(separator: "\n")
        if !message.isEmpty { messages.append(Data(message.utf8)) }
        fields.removeAll(keepingCapacity: true)
      } else if line.hasPrefix("data:") {
        var field = line.dropFirst(5)
        if field.first == " " { field = field.dropFirst() }
        fields.append(field)
      }
    }
    return messages
  }

  private func disconnect() async {
    if disconnectTask == nil {
      // Both forwarding tasks can finish together; their cancellation must not cancel session cleanup.
      disconnectTask = Task.detached { [upstream, stdio, connection] in
        let sessionID = await upstream.sessionID
        let version = await upstream.protocolVersion
        await upstream.disconnect()
        await stdio.disconnect()
        await connection.closeSession(sessionID, protocolVersion: version)
      }
    }
    await disconnectTask?.value
  }

  private func recordFailure(_ error: any Error) async {
    guard disconnectTask == nil else { return }
    failure = error
    await disconnect()
  }

  private struct Envelope: Decodable {
    let id: ID?
    let method: String?
    let result: Initialization?

    enum ID: Decodable, Equatable {
      case string(String)
      case integer(Int)

      init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let string = try? value.decode(String.self) {
          self = .string(string)
        } else {
          self = .integer(try value.decode(Int.self))
        }
      }
    }

    struct Initialization: Decodable {
      let protocolVersion: String?
    }
  }
}
