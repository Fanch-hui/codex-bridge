#if canImport(Darwin) || canImport(Glibc)
  #if canImport(Darwin)
    import Darwin
  #else
    import Glibc
  #endif

  enum POSIXSystem {
    static func open(_ path: String, _ flags: Int32) -> Int32 {
      #if canImport(Darwin)
        Darwin.open(path, flags)
      #else
        Glibc.open(path, flags)
      #endif
    }

    static func close(_ descriptor: Int32) {
      #if canImport(Darwin)
        _ = Darwin.close(descriptor)
      #else
        _ = Glibc.close(descriptor)
      #endif
    }

    static func read(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
      #if canImport(Darwin)
        Darwin.read(descriptor, buffer, count)
      #else
        Glibc.read(descriptor, buffer, count)
      #endif
    }

    static func write(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
      #if canImport(Darwin)
        Darwin.write(descriptor, buffer, count)
      #else
        Glibc.write(descriptor, buffer, count)
      #endif
    }

    static func lstat(_ path: UnsafePointer<CChar>, _ metadata: UnsafeMutablePointer<stat>) -> Int32
    {
      #if canImport(Darwin)
        Darwin.lstat(path, metadata)
      #else
        Glibc.lstat(path, metadata)
      #endif
    }

    static func kill(_ process: pid_t, _ signal: Int32) -> Int32 {
      #if canImport(Darwin)
        Darwin.kill(process, signal)
      #else
        Glibc.kill(process, signal)
      #endif
    }
  }
#endif
