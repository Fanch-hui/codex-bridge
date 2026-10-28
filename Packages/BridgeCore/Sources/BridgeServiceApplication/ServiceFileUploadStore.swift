import BridgeMCP
import BridgeSecurity
import Foundation

actor ServiceFileUploadStore {
  struct Upload: Sendable {
    let request: MCPFileUploadRequest
    let content: Data
    let receipt: MCPDirectWriteReceipt?
  }

  private struct Entry {
    let owner: MCPClientID
    let request: MCPFileUploadRequest
    var expiresAt: Date
    var content = Data()
    var committing = false
    var receipt: MCPDirectWriteReceipt?
    var cancelled = false

    var active: Bool { receipt == nil && !cancelled }
  }

  private var entries: [String: Entry] = [:]
  private let lifetime: TimeInterval

  init(lifetime: TimeInterval = 15 * 60) {
    self.lifetime = lifetime
  }

  func begin(_ request: MCPFileUploadRequest, owner: MCPClientID) throws -> MCPFileTransfer {
    expire()
    guard (0...MCPFileTransferLimits.maximumFileBytes).contains(request.byteCount),
      Self.isDigest(request.sha256),
      request.mode == "create" || request.mode == "replace",
      request.expectedSHA256.map(Self.isDigest) ?? true,
      request.mode != "replace" || request.expectedSHA256 != nil
    else { throw BridgeMCPQueryError.contractRejected }
    let active = entries.values.filter(\.active)
    guard active.count < 8,
      active.reduce(0, { $0 + $1.request.byteCount }) + request.byteCount <= 32 * 1_024 * 1_024,
      entries.count < 64
    else { throw BridgeMCPQueryError.busy }
    let id = "transfer-" + UUID().uuidString.lowercased()
    let entry = Entry(
      owner: owner, request: request, expiresAt: Date().addingTimeInterval(lifetime))
    entries[id] = entry
    scheduleExpiry()
    return transfer(id, entry)
  }

  func append(_ id: String, owner: MCPClientID, offset: Int, data: Data) throws -> MCPFileTransfer {
    var entry = try owned(id, owner: owner)
    guard entry.active, !entry.committing, offset >= 0,
      !data.isEmpty, data.count <= MCPFileTransferLimits.maximumChunkBytes,
      offset <= entry.content.count, data.count <= entry.request.byteCount - offset
    else { throw BridgeMCPQueryError.contractRejected }
    if offset < entry.content.count {
      guard data.count <= entry.content.count - offset,
        entry.content.subdata(in: offset..<(offset + data.count)) == data
      else { throw BridgeMCPQueryError.idempotencyConflict }
    } else {
      entry.content.append(data)
      entries[id] = entry
    }
    return transfer(id, entry)
  }

  func startCommit(_ id: String, owner: MCPClientID) throws -> Upload {
    var entry = try owned(id, owner: owner)
    if let receipt = entry.receipt {
      return Upload(request: entry.request, content: Data(), receipt: receipt)
    }
    guard !entry.cancelled else { throw BridgeMCPQueryError.contractRejected }
    guard !entry.committing else { throw BridgeMCPQueryError.busy }
    guard entry.content.count == entry.request.byteCount else {
      throw BridgeMCPQueryError.contractRejected
    }
    guard SecureFileRevision.digest(of: entry.content).sha256 == entry.request.sha256 else {
      throw BridgeMCPQueryError.fileRevisionConflict
    }
    entry.committing = true
    entries[id] = entry
    return Upload(request: entry.request, content: entry.content, receipt: nil)
  }

  func finishCommit(_ id: String, receipt: MCPDirectWriteReceipt) {
    guard var entry = entries[id] else { return }
    entry.receipt = receipt
    entry.committing = false
    entry.content = Data()
    entry.expiresAt = Date().addingTimeInterval(lifetime)
    entries[id] = entry
    scheduleExpiry()
  }

  func abandonCommit(_ id: String) {
    guard var entry = entries[id] else { return }
    entry.committing = false
    entries[id] = entry
    expire()
  }

  func cancel(_ id: String, owner: MCPClientID) throws -> MCPFileTransfer {
    var entry = try owned(id, owner: owner)
    guard !entry.committing else { throw BridgeMCPQueryError.busy }
    guard entry.receipt == nil else { throw BridgeMCPQueryError.contractRejected }
    entry.cancelled = true
    entry.content = Data()
    entries[id] = entry
    return transfer(id, entry)
  }

  private func owned(_ id: String, owner: MCPClientID) throws -> Entry {
    expire()
    guard let entry = entries[id], entry.owner == owner else {
      throw BridgeMCPQueryError.contractRejected
    }
    return entry
  }

  private func expire() {
    let now = Date()
    entries = entries.filter { $0.value.committing || $0.value.expiresAt > now }
  }

  private func scheduleExpiry() {
    Task { [weak self, lifetime] in
      try? await Task.sleep(for: .seconds(lifetime))
      await self?.expire()
    }
  }

  private func transfer(_ id: String, _ entry: Entry) -> MCPFileTransfer {
    let status: String
    if entry.cancelled {
      status = "cancelled"
    } else if entry.receipt != nil {
      status = "completed"
    } else {
      status = "uploading"
    }
    return MCPFileTransfer(
      transferID: id, status: status,
      receivedBytes: entry.receipt == nil ? entry.content.count : entry.request.byteCount,
      totalBytes: entry.request.byteCount,
      expiresAt: ISO8601DateFormatter().string(from: entry.expiresAt)
    )
  }

  static func isDigest(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}
