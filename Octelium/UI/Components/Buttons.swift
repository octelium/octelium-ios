import SwiftUI

enum ButtonVariant {
    case filled
    case outline
    case `default`
    case subtle
}

enum ButtonSize {
    case xs
    case sm
    case md
    case lg

    var height: CGFloat {
        switch self {
        case .xs: 30
        case .sm: 36
        case .md: 44
        case .lg: 50
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .xs: 12
        case .sm: 14
        case .md: 16
        case .lg: 17
        }
    }

    var paddingHorizontal: CGFloat {
        switch self {
        case .xs: 12
        case .sm: 16
        case .md: 20
        case .lg: 24
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .xs: 12
        case .sm: 14
        case .md: 15
        case .lg: 16
        }
    }
}

private struct OctButtonStyle: ButtonStyle {
    @Environment(\.octColors) private var colors
    @Environment(\.isEnabled) private var isEnabled

    let variant: ButtonVariant
    let size: ButtonSize
    let isDanger: Bool
    let fullWidth: Bool

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed
        let danger = AlertTone.red.getColors(colors.isDark)
        let dangerColor = getDangerColor(colors.isDark)

        let (background, content, border): (Color, Color, Color) = {
            if !isEnabled {
                return (colors.surface3, colors.faint, .clear)
            }

            switch variant {
            case .filled:
                if isDanger {
                    return (dangerColor, .white, .clear)
                }
                return (isPressed ? colors.inverseHover : colors.inverse, colors.inverseFg, .clear)
            case .outline:
                if isDanger {
                    return (isPressed ? danger.background : .clear, dangerColor, dangerColor)
                }
                return (isPressed ? colors.surface3 : .clear, colors.inverse, colors.inverse)
            case .default:
                return (isPressed ? colors.surface3 : colors.surface, colors.strong, colors.lineStrong)
            case .subtle:
                return (isPressed ? colors.surface3 : .clear, isDanger ? dangerColor : colors.muted, .clear)
            }
        }()

        return configuration.label
            .foregroundStyle(content)
            .padding(.horizontal, size.paddingHorizontal)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: size.height)
            .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(border, lineWidth: 1))
            .shadow(
                color: .black.opacity(variant == .filled && isEnabled && !colors.isDark ? 0.18 : 0),
                radius: isPressed ? 1 : 3,
                y: isPressed ? 0 : 1
            )
            .offset(y: isPressed && isEnabled ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: isPressed)
    }
}

struct OctButton: View {
    let text: String
    var icon: String?
    var variant: ButtonVariant = .filled
    var size: ButtonSize = .sm
    var isDanger = false
    var isLoading = false
    var isEnabled = true
    var fullWidth = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                HStack(spacing: 8) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: size.iconSize, weight: .semibold))
                    }

                    Text(text)
                        .font(.ubuntu(size.fontSize, .bold))
                        .lineLimit(1)
                }
                .opacity(isLoading ? 0 : 1)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .buttonStyle(OctButtonStyle(variant: variant, size: size, isDanger: isDanger, fullWidth: fullWidth))
        .disabled(!isEnabled || isLoading)
        .sensoryFeedback(.impact(weight: .light), trigger: isLoading) { _, new in new }
    }
}

struct OctIconButton: View {
    @Environment(\.octColors) private var colors

    let icon: String
    let label: String
    var variant: ButtonVariant = .subtle
    var size: CGFloat = 36
    var iconSize: CGFloat = 16
    var tint: Color?
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(tint ?? (variant == .default ? colors.strong : colors.faint))
                .frame(width: size, height: size)
                .background(
                    variant == .default ? colors.surface : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(variant == .default ? colors.lineStrong : .clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }
}

struct TextLinkButton: View {
    @Environment(\.octColors) private var colors

    let text: String
    var trailingIcon: String?
    var isExpanded = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(text)
                    .font(.ubuntu(14, .medium))

                if let trailingIcon {
                    Image(systemName: trailingIcon)
                        .font(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
            }
            .foregroundStyle(colors.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: isExpanded)
    }
}
