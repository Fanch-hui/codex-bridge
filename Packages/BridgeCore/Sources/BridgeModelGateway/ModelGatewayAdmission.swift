import Foundation
@preconcurrency import NIOCore

final class ModelGatewayLease: @unchecked Sendable {
  private let lock = NSLock()
  private var admission: ModelGatewayAdmission?
  let channelID: ObjectIdentifier

  init(_ admission: ModelGatewayAdmission, channelID: ObjectIdentifier) {
    self.admission = admission
    self.channelID = channelID
  }

  func release() {
    let admission = lock.withLock { () -> ModelGatewayAdmission? in
      defer { self.admission = nil }
      return self.admission
    }
    admission?.release(channelID)
  }

  deinit { release() }
}

/// Tracks transport requests until their handlers return, including after a disconnect.
final class ModelGatewayAdmission: @unchecked Sendable {
  private let lock = NSLock()
  private let maximumConnections: Int
  private let maximumRequests: Int
  private var channels: [ObjectIdentifier: any Channel] = [:]
  private var requests: Set<ObjectIdentifier> = []
  private var stopping = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(maximumConnections: Int, maximumRequests: Int) {
    self.maximumConnections = maximumConnections
    self.maximumRequests = maximumRequests
  }

  func register(_ channel: any Channel) -> Bool {
    lock.withLock {
      guard !stopping, channels.count < maximumConnections else { return false }
      channels[ObjectIdentifier(channel)] = channel
      return true
    }
  }

  func unregister(_ channel: any Channel) {
    _ = lock.withLock { channels.removeValue(forKey: ObjectIdentifier(channel)) }
  }

  func admit(_ channel: any Channel) -> ModelGatewayLease? {
    lock.withLock {
      let id = ObjectIdentifier(channel)
      guard !stopping, requests.count < maximumRequests, !requests.contains(id) else {
        return nil
      }
      requests.insert(id)
      return ModelGatewayLease(self, channelID: id)
    }
  }

  func release(_ id: ObjectIdentifier) {
    let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
      guard requests.remove(id) != nil, requests.isEmpty else { return [] }
      defer { waiters.removeAll() }
      return waiters
    }
    for continuation in pending { continuation.resume() }
  }

  func stopAccepting() -> [any Channel] {
    lock.withLock {
      stopping = true
      return channels.filter { !requests.contains($0.key) }.map(\.value)
    }
  }

  func allChannels() -> [any Channel] {
    lock.withLock { Array(channels.values) }
  }

  func waitForDrain() async {
    await withCheckedContinuation { continuation in
      let ready = lock.withLock {
        if requests.isEmpty { return true }
        waiters.append(continuation)
        return false
      }
      if ready { continuation.resume() }
    }
  }

  func reset() {
    lock.withLock {
      precondition(requests.isEmpty)
      channels.removeAll()
      stopping = false
    }
  }
}
