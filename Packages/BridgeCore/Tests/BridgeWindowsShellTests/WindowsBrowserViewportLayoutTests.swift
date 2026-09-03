#if os(Windows)
  import BridgeDesktopUI
  import WinSDK
  import XCTest
  @testable import BridgeWindowsShell

  final class WindowsBrowserViewportLayoutTests: XCTestCase {
    func testStandardDpiViewportMapping() {
      let viewport = BridgeDesktopBrowserViewport(
        x: 280,
        y: 56,
        width: 800,
        height: 600,
        visible: true
      )
      let bounds = RECT(left: 0, top: 0, right: 1200, bottom: 800)
      let rect = WindowsMainWindow.browserViewportRect(viewport, in: bounds, dpi: 96)

      XCTAssertEqual(rect.left, 280)
      XCTAssertEqual(rect.top, 56)
      XCTAssertEqual(rect.right, 1080)
      XCTAssertEqual(rect.bottom, 656)
    }

    func testScaledDpiViewportMapping() {
      let viewport = BridgeDesktopBrowserViewport(
        x: 200,
        y: 50,
        width: 600,
        height: 400,
        visible: true
      )
      let bounds = RECT(left: 0, top: 0, right: 1800, bottom: 1200)
      // 144 DPI = 1.5x scale
      let rect = WindowsMainWindow.browserViewportRect(viewport, in: bounds, dpi: 144)

      XCTAssertEqual(rect.left, 300)
      XCTAssertEqual(rect.top, 75)
      XCTAssertEqual(rect.right, 1200)
      XCTAssertEqual(rect.bottom, 675)
    }

    func testViewportClampsToClientBounds() {
      let viewport = BridgeDesktopBrowserViewport(
        x: 1000,
        y: 700,
        width: 800,
        height: 600,
        visible: true
      )
      let bounds = RECT(left: 0, top: 0, right: 1200, bottom: 800)
      let rect = WindowsMainWindow.browserViewportRect(viewport, in: bounds, dpi: 96)

      XCTAssertEqual(rect.left, 1000)
      XCTAssertEqual(rect.top, 700)
      XCTAssertEqual(rect.right, 1200)
      XCTAssertEqual(rect.bottom, 800)
    }

    func testNonFiniteCoordinatesDefaultToZero() {
      let viewport = BridgeDesktopBrowserViewport(
        x: .nan,
        y: .infinity,
        width: 500,
        height: 400,
        visible: true
      )
      let bounds = RECT(left: 0, top: 0, right: 1000, bottom: 800)
      let rect = WindowsMainWindow.browserViewportRect(viewport, in: bounds, dpi: 96)

      XCTAssertEqual(rect.left, 0)
      XCTAssertEqual(rect.top, 0)
      XCTAssertEqual(rect.right, 500)
      XCTAssertEqual(rect.bottom, 400)
    }
  }
#endif
