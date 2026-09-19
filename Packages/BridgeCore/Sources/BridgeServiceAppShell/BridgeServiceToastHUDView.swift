import BridgeServiceAppCore
import SwiftUI

public struct ToastHUDView: View {
  let toast: ToastNotice
  var onDismiss: (() -> Void)? = nil

  public init(toast: ToastNotice, onDismiss: (() -> Void)? = nil) {
    self.toast = toast
    self.onDismiss = onDismiss
  }

  public var body: some View {
    HStack(spacing: 10) {
      Image(systemName: toast.symbol)
        .font(.system(size: 14, weight: .bold))
        .foregroundStyle(toast.tone.foregroundColor)

      Text(toast.message)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.primary)

      if let onDismiss {
        Button {
          onDismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.leading, 4)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.regularMaterial)
    .clipShape(Capsule())
    .overlay(
      Capsule()
        .strokeBorder(toast.tone.borderColor, lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 4)
    .transition(
      .asymmetric(
        insertion: .move(edge: .bottom).combined(with: .opacity).combined(
          with: .scale(scale: 0.95)),
        removal: .opacity.combined(with: .scale(scale: 0.9))
      ))
  }
}
