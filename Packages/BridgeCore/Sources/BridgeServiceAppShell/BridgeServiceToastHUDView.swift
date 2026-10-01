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
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: toast.symbol)
        .font(.system(size: toast.title == nil ? 14 : 22, weight: .bold))
        .foregroundStyle(toast.tone.foregroundColor)

      VStack(alignment: .leading, spacing: 6) {
        if let title = toast.title {
          Text(title)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.primary)
        }
        Text(toast.message)
          .font(.system(size: toast.title == nil ? 13 : 14, weight: .medium))
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let onDismiss {
        Button {
          onDismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("关闭提示")
        .padding(.leading, 4)
      }
    }
    .frame(maxWidth: toast.title == nil ? nil : 500, alignment: .leading)
    .padding(.horizontal, toast.title == nil ? 14 : 18)
    .padding(.vertical, toast.title == nil ? 10 : 16)
    .background(toast.title == nil ? Color.clear : toast.tone.backgroundColor)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: toast.title == nil ? 24 : 12))
    .overlay(
      RoundedRectangle(cornerRadius: toast.title == nil ? 24 : 12)
        .strokeBorder(
          toast.title == nil ? toast.tone.borderColor : toast.tone.foregroundColor,
          lineWidth: toast.title == nil ? 1 : 2)
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
