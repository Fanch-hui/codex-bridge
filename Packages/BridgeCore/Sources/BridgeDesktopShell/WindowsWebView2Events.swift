#if os(Windows)
  import Foundation
  import WinSDK

  private let historyChangedIID = makeEventGUID(
    0xC79A_420C, 0xEFD9, 0x4058,
    (0x92, 0x95, 0x3E, 0x8B, 0x4B, 0xCA, 0xB6, 0x45)
  )
  private let navigationCompletedIID = makeEventGUID(
    0xD33A_35BF, 0x1C49, 0x4F98,
    (0x93, 0xAB, 0x00, 0x6E, 0x05, 0x33, 0xFE, 0x1C)
  )
  private let unknownIID = makeEventGUID(
    0x0000_0000, 0x0000, 0x0000,
    (0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46)
  )

  private func makeEventGUID(
    _ data1: UInt32,
    _ data2: UInt16,
    _ data3: UInt16,
    _ data4: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
  ) -> GUID {
    var guid = GUID()
    guid.Data1 = data1
    guid.Data2 = data2
    guid.Data3 = data3
    guid.Data4 = data4
    return guid
  }

  private func equalEventGUID(_ lhs: GUID, _ rhs: GUID) -> Bool {
    lhs.Data1 == rhs.Data1 && lhs.Data2 == rhs.Data2 && lhs.Data3 == rhs.Data3
      && lhs.Data4.0 == rhs.Data4.0 && lhs.Data4.1 == rhs.Data4.1
      && lhs.Data4.2 == rhs.Data4.2 && lhs.Data4.3 == rhs.Data4.3
      && lhs.Data4.4 == rhs.Data4.4 && lhs.Data4.5 == rhs.Data4.5
      && lhs.Data4.6 == rhs.Data4.6 && lhs.Data4.7 == rhs.Data4.7
  }

  final class EventHandlerContext {
    let onEvent: @Sendable (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

    init(onEvent: @escaping @Sendable (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void)
    {
      self.onEvent = onEvent
    }
  }

  private struct EventHandlerObject {
    var vtable: UnsafeMutablePointer<EventHandlerVTable>
    var refCount: UInt32
    var context: Unmanaged<EventHandlerContext>
    var eventIID: GUID
  }

  private struct EventHandlerVTable {
    var queryInterface:
      @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<GUID>?,
        UnsafeMutablePointer<UnsafeMutableRawPointer?>?
      ) -> HRESULT
    var addRef: @convention(c) (UnsafeMutableRawPointer?) -> UInt32
    var release: @convention(c) (UnsafeMutableRawPointer?) -> UInt32
    var invoke:
      @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
      ) -> HRESULT
  }

  func webView2EventHandler(
    eventIID: GUID,
    _ onEvent: @escaping @Sendable (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
  ) -> UnsafeMutableRawPointer {
    let vtable = UnsafeMutablePointer<EventHandlerVTable>.allocate(capacity: 1)
    vtable.initialize(
      to: EventHandlerVTable(
        queryInterface: eventHandlerQueryInterface,
        addRef: eventHandlerAddRef,
        release: eventHandlerRelease,
        invoke: eventHandlerInvoke
      )
    )
    let object = UnsafeMutablePointer<EventHandlerObject>.allocate(capacity: 1)
    object.initialize(
      to: EventHandlerObject(
        vtable: vtable,
        refCount: 1,
        context: Unmanaged.passRetained(EventHandlerContext(onEvent: onEvent)),
        eventIID: eventIID
      )
    )
    return UnsafeMutableRawPointer(object)
  }

  func webView2HistoryChangedHandler(
    _ onEvent: @escaping @Sendable (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
  ) -> UnsafeMutableRawPointer {
    webView2EventHandler(eventIID: historyChangedIID, onEvent)
  }

  func webView2NavigationCompletedHandler(
    _ onEvent: @escaping @Sendable (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
  ) -> UnsafeMutableRawPointer {
    webView2EventHandler(eventIID: navigationCompletedIID, onEvent)
  }

  private func eventHandlerQueryInterface(
    _ this: UnsafeMutableRawPointer?,
    _ iid: UnsafePointer<GUID>?,
    _ output: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
  ) -> HRESULT {
    guard let this, let iid, let output else { return HRESULT(bitPattern: 0x8000_4003) }
    output.pointee = nil
    let object = this.assumingMemoryBound(to: EventHandlerObject.self)
    guard
      equalEventGUID(iid.pointee, unknownIID)
        || equalEventGUID(iid.pointee, object.pointee.eventIID)
    else { return HRESULT(bitPattern: 0x8000_4002) }
    output.pointee = this
    _ = eventHandlerAddRef(this)
    return 0
  }

  private func eventHandlerAddRef(_ this: UnsafeMutableRawPointer?) -> UInt32 {
    guard let this else { return 0 }
    let object = this.assumingMemoryBound(to: EventHandlerObject.self)
    object.pointee.refCount += 1
    return object.pointee.refCount
  }

  private func eventHandlerRelease(_ this: UnsafeMutableRawPointer?) -> UInt32 {
    guard let this else { return 0 }
    let object = this.assumingMemoryBound(to: EventHandlerObject.self)
    object.pointee.refCount -= 1
    let refCount = object.pointee.refCount
    if refCount == 0 {
      let context = object.pointee.context
      let vtable = object.pointee.vtable
      object.deinitialize(count: 1)
      object.deallocate()
      context.release()
      vtable.deinitialize(count: 1)
      vtable.deallocate()
    }
    return refCount
  }

  private func eventHandlerInvoke(
    _ this: UnsafeMutableRawPointer?,
    _ sender: UnsafeMutableRawPointer?,
    _ args: UnsafeMutableRawPointer?
  ) -> HRESULT {
    guard let this else { return HRESULT(bitPattern: 0x8000_4003) }
    let object = this.assumingMemoryBound(to: EventHandlerObject.self)
    object.pointee.context.takeUnretainedValue().onEvent(sender, args)
    return 0
  }
#endif
