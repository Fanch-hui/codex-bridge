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

  }
#endif
