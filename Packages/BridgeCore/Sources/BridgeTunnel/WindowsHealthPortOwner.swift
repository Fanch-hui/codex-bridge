#if os(Windows)
  import WinSDK

  /// Checks that the loopback health listener belongs to the tunnel helper.
  enum WindowsHealthPortOwner {
    typealias TableQuery = (UnsafeMutableRawPointer?, UnsafeMutablePointer<DWORD>) -> DWORD

    private static let maximumTableAttempts = 3

    static func owns(
      port: Int,
      processID: Int32,
      diagnostics: TunnelStartupDiagnostics? = nil
    ) throws -> Bool {
      try owns(port: port, processID: processID, diagnostics: diagnostics) { table, size in
        GetExtendedTcpTable(table, size, false, ULONG(AF_INET), TCP_TABLE_OWNER_PID_ALL, 0)
      }
    }

    static func owns(
      port: Int,
      processID: Int32,
      diagnostics: TunnelStartupDiagnostics? = nil,
      query: TableQuery
    ) throws -> Bool {
      guard port > 0, port <= 65_535, processID > 0 else { return false }

      var size: DWORD = 0
      let status = query(nil, &size)
      guard status == ERROR_INSUFFICIENT_BUFFER else {
        throw queryFailure(status == 0 ? DWORD(ERROR_INVALID_DATA) : status)
      }

      for _ in 0..<maximumTableAttempts {
        if let matches = try inspectTable(
          port: UInt16(port),
          processID: DWORD(bitPattern: processID),
          diagnostics: diagnostics,
          size: &size,
          query: query
        ) {
          return matches
        }
      }
      throw queryFailure(DWORD(ERROR_INSUFFICIENT_BUFFER))
    }

    private static func inspectTable(
      port: UInt16,
      processID: DWORD,
      diagnostics: TunnelStartupDiagnostics?,
      size: inout DWORD,
      query: TableQuery
    ) throws -> Bool? {
      let rowOffset =
        MemoryLayout<MIB_TCPTABLE_OWNER_PID>.offset(of: \.table)
        ?? MemoryLayout<DWORD>.stride
      let rowStride = MemoryLayout<MIB_TCPROW_OWNER_PID>.stride
      let capacity = Int(size)
      guard rowOffset >= MemoryLayout<DWORD>.size,
        rowOffset.isMultiple(of: MemoryLayout<MIB_TCPROW_OWNER_PID>.alignment),
        capacity >= rowOffset
      else { throw queryFailure(DWORD(ERROR_INVALID_DATA)) }

      let alignment = max(
        MemoryLayout<DWORD>.alignment, MemoryLayout<MIB_TCPROW_OWNER_PID>.alignment)
      let storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: alignment)
      defer { storage.deallocate() }
      let header = storage.bindMemory(to: DWORD.self, capacity: 1)
      let rowCapacity = (capacity - rowOffset) / rowStride
      let rows: UnsafeMutablePointer<MIB_TCPROW_OWNER_PID>?
      if rowCapacity > 0 {
        rows = storage.advanced(by: rowOffset).bindMemory(
          to: MIB_TCPROW_OWNER_PID.self, capacity: rowCapacity)
      } else {
        rows = nil
      }

      let status = query(storage, &size)
      if status == ERROR_INSUFFICIENT_BUFFER { return nil }
      guard status == 0 else { throw queryFailure(status) }
      guard Int(size) >= rowOffset, Int(size) <= capacity else {
        throw queryFailure(DWORD(ERROR_INVALID_DATA))
      }
      let count = Int(header.pointee)
      guard count <= (Int(size) - rowOffset) / rowStride else {
        throw queryFailure(DWORD(ERROR_INVALID_DATA))
      }
      return matchesOwner(
        rows: UnsafeBufferPointer(start: rows, count: count),
        port: port,
        processID: processID,
        diagnostics: diagnostics
      )
    }

    private static func matchesOwner(
      rows: UnsafeBufferPointer<MIB_TCPROW_OWNER_PID>,
      port: UInt16,
      processID: DWORD,
      diagnostics: TunnelStartupDiagnostics?
    ) -> Bool {
      var portRows: Int64 = 0
      var listenRows: Int64 = 0
      var processRows: Int64 = 0
      for row in rows {
        guard ntohs(UInt16(truncatingIfNeeded: row.dwLocalPort)) == port else { continue }
        portRows += 1
        let matchesProcess = row.dwOwningPid == processID
        if matchesProcess { processRows += 1 }
        guard row.dwState == MIB_TCP_STATE_LISTEN.rawValue else { continue }
        listenRows += 1
        if matchesProcess { return true }
      }
      diagnostics?.recordHealthCheck(
        .healthPeerMismatch,
        fields: ["port_rows": portRows, "listen_rows": listenRows, "pid_rows": processRows]
      )
      return false
    }

    private static func queryFailure(_ status: DWORD) -> TunnelHealthError {
      .portTableQueryFailed(status)
    }
  }
#endif
