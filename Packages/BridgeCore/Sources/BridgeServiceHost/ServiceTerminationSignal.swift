#if !os(Windows)
  import Foundation
  #if canImport(Darwin)
    import Darwin
  #else
    import Glibc
  #endif

  enum ServiceTerminationSignal {
    private static let defaultState = SignalState()

    static func wait() async {
      await wait(state: defaultState, signals: [SIGINT, SIGTERM])
    }

    static func request() { defaultState.finish() }

    static func wait(for signals: [Int32]) async {
      await wait(state: SignalState(), signals: signals)
    }

    private static func wait(state: SignalState, signals: [Int32]) async {
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          state.start(continuation: continuation, signals: signals)
        }
      } onCancel: {
        state.finish()
      }
    }
  }

  private final class SignalState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var sources: [DispatchSourceSignal] = []
    private var previousHandlers: [(signal: Int32, handler: (@convention(c) (Int32) -> Void)?)] = []
    private var finished = false

    func start(
      continuation: CheckedContinuation<Void, Never>,
      signals: [Int32]
    ) {
      lock.lock()
      if finished {
        lock.unlock()
        continuation.resume()
        return
      }
      self.continuation = continuation
      lock.unlock()

      var installedSignals: [Int32] = []
      for signal in signals where !installedSignals.contains(signal) {
        installedSignals.append(signal)
        install(signal: signal)
      }
      if Task.isCancelled {
        finish()
      }
    }

    func install(signal: Int32) {
      lock.lock()
      guard !finished else {
        lock.unlock()
        return
      }
      let previousHandler = setSignalHandler(signal, SIG_IGN)
      previousHandlers.append((signal: signal, handler: previousHandler))
      let source = DispatchSource.makeSignalSource(signal: signal, queue: .global())
      source.setEventHandler { [self] in self.finish() }
      sources.append(source)
      source.resume()
      lock.unlock()
    }

    func finish() {
      lock.lock()
      guard !finished else {
        lock.unlock()
        return
      }
      finished = true
      let continuation = continuation
      self.continuation = nil
      let activeSources = sources
      sources.removeAll(keepingCapacity: false)
      let handlers = previousHandlers
      previousHandlers.removeAll(keepingCapacity: false)
      lock.unlock()
      for source in activeSources { source.cancel() }
      for handler in handlers {
        _ = setSignalHandler(handler.signal, handler.handler)
      }
      continuation?.resume()
    }

    private func setSignalHandler(
      _ number: Int32, _ handler: (@convention(c) (Int32) -> Void)?
    ) -> (@convention(c) (Int32) -> Void)? {
      #if canImport(Darwin)
        return Darwin.signal(number, handler)
      #else
        return Glibc.signal(number, handler)
      #endif
    }
  }
#endif
