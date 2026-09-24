import OcteliumCore
import SwiftUI
import UIKit

struct SectionCard<Content: View>: View {
    @Environment(\.octColors) private var colors

    var padding: CGFloat = 20
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(colors.line, lineWidth: 1))
        .shadow(color: .black.opacity(colors.isDark ? 0 : 0.04), radius: 2, y: 1)
    }
}

struct LineDivider: View {
    @Environment(\.octColors) private var colors

    var body: some View {
        Rectangle()
            .fill(colors.line)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

struct SectionTitle: View {
    @Environment(\.octColors) private var colors

    let text: String

    var body: some View {
        Text(text)
            .font(.ubuntu(14, .bold, relativeTo: .headline))
            .foregroundStyle(colors.strong)
    }
}

struct PageHeader<Actions: View>: View {
    @Environment(\.octColors) private var colors

    let title: String
    var description: String?
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.ubuntu(24, .bold, relativeTo: .title2))
                .foregroundStyle(colors.strong)
                .accessibilityAddTraits(.isHeader)

            if let description {
                Text(description)
                    .font(.ubuntu(14, .medium))
                    .foregroundStyle(colors.muted)
                    .padding(.top, 4)
            }

            HStack(spacing: 8) {
                actions()
            }
            .padding(.top, 12)

            LineDivider()
                .padding(.top, 18)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension PageHeader where Actions == EmptyView {
    init(title: String, description: String? = nil) {
        self.title = title
        self.description = description
        self.actions = { EmptyView() }
    }
}

struct InfoItem<Content: View>: View {
    @Environment(\.octColors) private var colors

    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.ubuntu(11, .bold, relativeTo: .caption))
                .kerning(0.5)
                .foregroundStyle(colors.faint)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InfoText: View {
    @Environment(\.octColors) private var colors

    let text: String

    var body: some View {
        Text(text)
            .font(.ubuntu(14, .medium))
            .foregroundStyle(colors.body)
    }
}

struct Mono: View {
    @Environment(\.octColors) private var colors

    let text: String
    var lineLimit: Int?

    var body: some View {
        Text(text)
            .font(.mono(13))
            .foregroundStyle(colors.body)
            .lineLimit(lineLimit)
            .textSelection(.enabled)
    }
}

struct InfoGridItem: Identifiable {
    let id = UUID()
    let title: String
    let content: AnyView

    init<Content: View>(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = AnyView(content())
    }
}

struct InfoGrid: View {
    var columns = 2
    let items: [InfoGridItem]

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading), count: columns),
            alignment: .leading,
            spacing: 16
        ) {
            ForEach(items) { itm in
                InfoItem(title: itm.title) {
                    itm.content
                }
            }
        }
    }
}

struct OctLabel: View {
    @Environment(\.octColors) private var colors

    let text: String
    var tone: LabelTone = .neutral
    var toneColors: ToneColors?
    var icon: String?
    var prefix: String?
    var isMono = false

    var body: some View {
        let tc = toneColors ?? getLabelToneColors(tone, colors.isDark)

        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tc.content.opacity(0.7))
            }

            if let prefix {
                Text(prefix)
                    .font(.ubuntu(12, .medium, relativeTo: .caption))
                    .foregroundStyle(colors.faint)
            }

            Text(text)
                .font(isMono ? .mono(12) : .ubuntu(12, .medium, relativeTo: .caption))
                .foregroundStyle(tc.content)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tc.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(tc.border, lineWidth: 1))
    }
}

struct StatusDot: View {
    @Environment(\.octColors) private var colors

    let tone: ConnectivityTone
    var size: CGFloat = 10
    var pulse = false

    @State private var isAnimating = false

    var body: some View {
        let color = getConnectivityToneColor(tone, colors.isDark)

        ZStack {
            if pulse {
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .scaleEffect(isAnimating ? 2 : 1)
                    .opacity(isAnimating ? 0 : 0.6)
                    .animation(.easeOut(duration: 1).repeatForever(autoreverses: false), value: isAnimating)
                    .onAppear {
                        isAnimating = true
                    }
                    .onDisappear {
                        isAnimating = false
                    }
            }

            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .animation(.smooth, value: tone)
        .accessibilityHidden(true)
    }
}

struct Notice: View {
    @Environment(\.octColors) private var colors

    var title: String?
    var icon: String? = "info.circle"
    let content: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(colors.faint)
                    .padding(.top, 1)
            }

            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .font(.ubuntu(14, .bold))
                        .foregroundStyle(colors.strong)
                }

                Text(content)
                    .font(.ubuntu(14, .medium))
                    .foregroundStyle(colors.muted)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(colors.line, lineWidth: 1))
    }
}

struct AlertBox<Content: View>: View {
    @Environment(\.octColors) private var colors

    let tone: AlertTone
    var title: String?
    var icon: String?
    var isLoading = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        let tc = tone.getColors(colors.isDark)

        HStack(alignment: .top, spacing: 12) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(tc.content)
                    .frame(width: 18, height: 18)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tc.content)
                    .frame(width: 18, height: 18)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let title {
                    Text(title)
                        .font(.ubuntu(14, .bold))
                        .foregroundStyle(tc.content)
                }

                content()
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tc.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

struct AlertText: View {
    @Environment(\.octColors) private var colors

    let text: String

    var body: some View {
        Text(text)
            .font(.ubuntu(14, .medium))
            .foregroundStyle(colors.body)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingRow<Trailing: View>: View {
    @Environment(\.octColors) private var colors

    let title: String
    var description: String?
    var isLast = false
    var isStacked = false
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isStacked {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    trailing()
                }
                .padding(.vertical, 14)
            } else {
                HStack(spacing: 16) {
                    header
                        .frame(maxWidth: .infinity, alignment: .leading)
                    trailing()
                }
                .padding(.vertical, 14)
            }

            if !isLast {
                LineDivider()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.ubuntu(14, .bold))
                .foregroundStyle(colors.strong)

            if let description {
                Text(description)
                    .font(.ubuntu(13, .medium, relativeTo: .footnote))
                    .foregroundStyle(colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct CopyText: View {
    @Environment(\.octColors) private var colors

    let value: String
    var isMono = true

    @State private var isCopied = false

    var body: some View {
        HStack(spacing: 4) {
            if isMono {
                Mono(text: value)
            } else {
                InfoText(text: value)
            }

            OctIconButton(
                icon: isCopied ? "checkmark" : "doc.on.doc",
                label: isCopied ? "Copied" : "Copy to clipboard",
                size: 28,
                iconSize: 13,
                tint: isCopied ? successColor : colors.body
            ) {
                UIPasteboard.general.string = value
                isCopied = true
            }
            .contentTransition(.symbolEffect(.replace))
            .sensoryFeedback(.success, trigger: isCopied) { _, new in new }
        }
        .task(id: isCopied) {
            guard isCopied else {
                return
            }

            try? await Task.sleep(for: .milliseconds(1200))
            isCopied = false
        }
    }
}

struct EmptyState<Action: View>: View {
    @Environment(\.octColors) private var colors

    let title: String
    var message: String?
    var icon = "tray"
    @ViewBuilder let action: () -> Action

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(colors.faint)
                .frame(width: 48, height: 48)
                .background(colors.surface3, in: Circle())
                .overlay(Circle().strokeBorder(colors.line, lineWidth: 1))

            Text(title)
                .font(.ubuntu(16, .bold, relativeTo: .headline))
                .foregroundStyle(colors.strong)
                .multilineTextAlignment(.center)
                .padding(.top, 16)

            if let message {
                Text(message)
                    .font(.ubuntu(14, .medium))
                    .foregroundStyle(colors.muted)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }

            action()
                .padding(.top, 20)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(colors.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(colors.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }
}

extension EmptyState where Action == EmptyView {
    init(title: String, message: String? = nil, icon: String = "tray") {
        self.title = title
        self.message = message
        self.icon = icon
        self.action = { EmptyView() }
    }
}

struct ErrorState: View {
    let title: String
    let message: String
    var onRetry: (() -> Void)?

    var body: some View {
        AlertBox(tone: .red, title: title, icon: "exclamationmark.circle") {
            AlertText(text: message)

            if let onRetry {
                OctButton(
                    text: "Try again",
                    icon: "arrow.clockwise",
                    variant: .outline,
                    size: .xs,
                    isDanger: true,
                    action: onRetry
                )
                .padding(.top, 6)
            }
        }
    }
}

struct SkeletonBox: View {
    @Environment(\.octColors) private var colors

    var width: CGFloat?
    var height: CGFloat
    var cornerRadius: CGFloat = 6

    @State private var isDimmed = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(colors.surface3)
            .frame(width: width, height: height)
            .opacity(isDimmed ? 0.5 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isDimmed)
            .onAppear {
                isDimmed = true
            }
    }
}

struct ResourceListSkeleton: View {
    var count = 5

    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<count, id: \.self) { _ in
                SectionCard(padding: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        SkeletonBox(width: 44, height: 44, cornerRadius: 22)

                        VStack(alignment: .leading, spacing: 10) {
                            SkeletonBox(width: 140, height: 14)

                            HStack(spacing: 8) {
                                SkeletonBox(width: 72, height: 18)
                                SkeletonBox(width: 96, height: 18)
                                SkeletonBox(width: 56, height: 18)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityLabel("Loading")
    }
}

struct Footer: View {
    @Environment(\.octColors) private var colors
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 8) {
            Text("Octelium is Free and Open Source Software")
                .font(.ubuntu(13, .bold, relativeTo: .footnote))
                .foregroundStyle(colors.body)

            Button {
                if let url = URL(string: "https://github.com/octelium/octelium") {
                    openURL(url)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                    Text("github.com/octelium/octelium")
                        .font(.ubuntu(13, .bold, relativeTo: .footnote))
                }
                .foregroundStyle(colors.muted)
                .padding(4)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
        .padding(.bottom, 16)
    }
}

struct ScreenScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content()
                Footer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}
