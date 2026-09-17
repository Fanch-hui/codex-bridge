#if os(Windows)
  import Foundation
  import WinSDK

  private let webMessageHandlerIID = webMessageGUID(
    0x5721_3F19, 0x00E6, 0x49FA,
    (0x8E, 0x07, 0x89, 0x8E, 0xA0, 0x1E, 0xCB, 0xD2)
  )
  private let unknownIID = webMessageGUID(
    0x0000_0000, 0x0000, 0x0000,
    (0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46)
  )
  private let noInterfaceHRESULT = HRESULT(bitPattern: 0x8000_4002)
  private let pointerHRESULT = HRESULT(bitPattern: 0x8000_4003)

  private func webMessageGUID(
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

  private func equalGUID(_ lhs: GUID, _ rhs: GUID) -> Bool {
    lhs.Data1 == rhs.Data1 && lhs.Data2 == rhs.Data2 && lhs.Data3 == rhs.Data3
      && lhs.Data4.0 == rhs.Data4.0 && lhs.Data4.1 == rhs.Data4.1
      && lhs.Data4.2 == rhs.Data4.2 && lhs.Data4.3 == rhs.Data4.3
      && lhs.Data4.4 == rhs.Data4.4 && lhs.Data4.5 == rhs.Data4.5
      && lhs.Data4.6 == rhs.Data4.6 && lhs.Data4.7 == rhs.Data4.7
  }

  final class WebMessageHandlerContext {
    let onMessage: @Sendable (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

    init(
      onMessage: @escaping @Sendable (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    ) {
      self.onMessage = onMessage
    }
  }

  private struct WebMessageHandlerObject {
    var vtable: UnsafeMutablePointer<WebMessageHandlerVTable>
    var refCount: UInt32
    var context: Unmanaged<WebMessageHandlerContext>
  }

  private struct WebMessageHandlerVTable {
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

  func webView2WebMessageHandler(
    _ onMessage: @escaping @Sendable (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
  ) -> UnsafeMutableRawPointer {
    let vtable = UnsafeMutablePointer<WebMessageHandlerVTable>.allocate(capacity: 1)
    vtable.initialize(
      to: WebMessageHandlerVTable(
        queryInterface: webMessageQueryInterface,
        addRef: webMessageAddRef,
        release: webMessageRelease,
        invoke: webMessageInvoke
      )
    )
    let object = UnsafeMutablePointer<WebMessageHandlerObject>.allocate(capacity: 1)
    object.initialize(
      to: WebMessageHandlerObject(
        vtable: vtable,
        refCount: 1,
        context: Unmanaged.passRetained(WebMessageHandlerContext(onMessage: onMessage))
      )
    )
    return UnsafeMutableRawPointer(object)
  }

  private func webMessageQueryInterface(
    _ this: UnsafeMutableRawPointer?,
    _ iid: UnsafePointer<GUID>?,
    _ output: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
  ) -> HRESULT {
    guard let this, let iid, let output else { return pointerHRESULT }
    output.pointee = nil
    guard equalGUID(iid.pointee, unknownIID) || equalGUID(iid.pointee, webMessageHandlerIID)
    else { return noInterfaceHRESULT }
    output.pointee = this
    _ = webMessageAddRef(this)
    return webview2SOK
  }

  private func webMessageAddRef(_ this: UnsafeMutableRawPointer?) -> UInt32 {
    guard let this else { return 0 }
    let object = this.assumingMemoryBound(to: WebMessageHandlerObject.self)
    object.pointee.refCount += 1
    return object.pointee.refCount
  }

  private func webMessageRelease(_ this: UnsafeMutableRawPointer?) -> UInt32 {
    guard let this else { return 0 }
    let object = this.assumingMemoryBound(to: WebMessageHandlerObject.self)
    object.pointee.refCount -= 1
    let refCount = object.pointee.refCount
    guard refCount == 0 else { return refCount }
    let context = object.pointee.context
    let vtable = object.pointee.vtable
    object.deinitialize(count: 1)
    object.deallocate()
    context.release()
    vtable.deinitialize(count: 1)
    vtable.deallocate()
    return 0
  }

  private func webMessageInvoke(
    _ this: UnsafeMutableRawPointer?,
    _ sender: UnsafeMutableRawPointer?,
    _ args: UnsafeMutableRawPointer?
  ) -> HRESULT {
    guard let this else { return pointerHRESULT }
    let context = this.assumingMemoryBound(to: WebMessageHandlerObject.self).pointee.context
    context.takeUnretainedValue().onMessage(sender, args)
    return webview2SOK
  }

  func webView2ReadWebMessageJSON(_ args: UnsafeMutableRawPointer?) -> String? {
    guard let args else { return nil }
    let getJSON: WebView2GetWebMessageAsJSONFn = webView2Method(
      args, 4, as: WebView2GetWebMessageAsJSONFn.self)
    var value: UnsafeMutableRawPointer?
    guard getJSON(args, &value) == webview2SOK, let value else { return nil }
    defer { CoTaskMemFree(value) }
    let pointer = value.assumingMemoryBound(to: WCHAR.self)
    var length = 0
    while pointer[length] != 0 { length += 1 }
    return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF16.self)
  }
#endif
