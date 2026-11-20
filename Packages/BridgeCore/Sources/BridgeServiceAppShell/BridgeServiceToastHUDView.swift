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
    HStack(alignment: toast.title == nil ? .center : .top, spacing: 10) {
      Image(systemName: toast.symbol)
        .font(.system(size: toast.title == nil ? 15 : 20, weight: .semibold))
        .foregroundStyle(toast.tone.foregroundColor)

      VStack(alignment: .leading, spacing: 4) {
        if let title = toast.title {
          Text(title)
            .font(.system(size: 15.5, weight: .bold))
            .foregroundStyle(.primary)
        }
        Text(toast.message)
          .font(.system(size: toast.title == nil ? 13 : 13.5, weight: .medium))
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let onDismiss {
        Button {
          onDismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("关闭提示")
        .padding(.leading, 2)
      }
    }
    .frame(maxWidth: toast.title == nil ? 380 : 500, alignment: .leading)
    .padding(.horizontal, toast.title == nil ? 14 : 18)
    .padding(.vertical, toast.title == nil ? 9 : 15)
    .background(toast.title == nil ? Color.clear : toast.tone.backgroundColor)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: toast.title == nil ? 12 : 13, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: toast.title == nil ? 12 : 13, style: .continuous)
        .strokeBorder(
          toast.title == nil ? toast.tone.borderColor : toast.tone.foregroundColor,
          lineWidth: toast.title == nil ? 0.75 : 1.5)
    )
    .shadow(color: Color.black.opacity(0.14), radius: 14, x: 0, y: 6)
    .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)
    .transition(
      .asymmetric(
        insertion: .move(edge: .bottom).combined(with: .opacity).combined(
          with: .scale(scale: 0.96)),
        removal: .opacity.combined(with: .scale(scale: 0.96))
      ))
  }
}
