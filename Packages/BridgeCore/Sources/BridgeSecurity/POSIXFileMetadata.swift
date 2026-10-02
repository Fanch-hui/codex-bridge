#if canImport(Darwin) || canImport(Glibc)
  #if canImport(Darwin)
    import Darwin
  #else
    import Glibc
  #endif

  extension stat {
    var modificationTime: timespec {
      #if canImport(Darwin)
        st_mtimespec
      #else
        st_mtim
      #endif
    }
  }
#endif
