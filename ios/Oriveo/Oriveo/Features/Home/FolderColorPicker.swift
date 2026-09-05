import SwiftUI

struct FolderColorPicker: View {
    @Binding var selectedColor: FolderColor
    var onDismiss: () -> Void

    private let columns = Array(repeating: GridItem(.fixed(44), spacing: 12), count: 5)

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(L10n.tr("Change Color", table: .home))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OriveoTheme.V2.Colors.textPrimary)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(OriveoTheme.V2.Colors.textTertiary)
                }
                .accessibilityLabel(L10n.tr("Close"))
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(FolderColor.ordered, id: \.self) { color in
                    Button {
                        selectedColor = color
                        onDismiss()
                    } label: {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: color.gradientColors,
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 36, height: 36)
                            .overlay(
                                Group {
                                    if color == selectedColor {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                            )
                            .shadow(color: color.color.opacity(0.3), radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(color.accessibilityLabel)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .background(OriveoTheme.V2.Colors.surfaceDefault)
    }
}
