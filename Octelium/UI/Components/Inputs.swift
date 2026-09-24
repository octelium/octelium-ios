import SwiftUI

struct FieldLabel: View {
    @Environment(\.octColors) private var colors

    let text: String

    var body: some View {
        Text(text)
            .font(.ubuntu(14, .medium))
            .foregroundStyle(colors.strong)
            .padding(.bottom, 6)
    }
}

struct OctTextField: View {
    @Environment(\.octColors) private var colors

    var label: String?
    var placeholder = ""
    @Binding var text: String
    var leadingIcon: String?
    var isSecure = false
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType?
    var submitLabel: SubmitLabel = .done
    var error: String?
    var onSubmit: () -> Void = {}

    @FocusState private var isFocused: Bool
    @State private var isRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label {
                FieldLabel(text: label)
            }

            HStack(spacing: 10) {
                if let leadingIcon {
                    Image(systemName: leadingIcon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(colors.faint)
                }

                Group {
                    if isSecure && !isRevealed {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .font(.ubuntu(16, .medium))
                .foregroundStyle(colors.strong)
                .keyboardType(keyboardType)
                .textContentType(textContentType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(submitLabel)
                .focused($isFocused)
                .onSubmit(onSubmit)

                if isSecure {
                    OctIconButton(
                        icon: isRevealed ? "eye.slash" : "eye",
                        label: isRevealed ? "Hide" : "Show",
                        size: 28,
                        iconSize: 14
                    ) {
                        isRevealed.toggle()
                    }
                }

                if !isSecure && !text.isEmpty && isFocused {
                    OctIconButton(icon: "xmark.circle.fill", label: "Clear", size: 26, iconSize: 14) {
                        text = ""
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        error != nil ? getDangerColor(colors.isDark) : (isFocused ? colors.inverse : colors.lineStrong),
                        lineWidth: 2
                    )
            )
            .animation(.easeOut(duration: 0.15), value: isFocused)

            if let error {
                Text(error)
                    .font(.ubuntu(12, .medium, relativeTo: .caption))
                    .foregroundStyle(getDangerColor(colors.isDark))
                    .padding(.top, 4)
            }
        }
    }
}

struct SelectOption<T: Hashable>: Hashable {
    let value: T
    let label: String
}

struct SelectField<T: Hashable>: View {
    @Environment(\.octColors) private var colors

    let options: [SelectOption<T>]
    let value: T?
    var label: String?
    var placeholder = "Select"
    var isClearable = false
    let onChange: (T?) -> Void

    var body: some View {
        let selected = options.first { $0.value == value }

        VStack(alignment: .leading, spacing: 0) {
            if let label {
                FieldLabel(text: label)
            }

            Menu {
                if isClearable {
                    Button {
                        onChange(nil)
                    } label: {
                        if value == nil {
                            Label(placeholder, systemImage: "checkmark")
                        } else {
                            Text(placeholder)
                        }
                    }

                    Divider()
                }

                ForEach(options, id: \.self) { itm in
                    Button {
                        onChange(itm.value)
                    } label: {
                        if itm.value == value {
                            Label(itm.label, systemImage: "checkmark")
                        } else {
                            Text(itm.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selected?.label ?? placeholder)
                        .font(.ubuntu(15, .medium))
                        .foregroundStyle(selected == nil ? colors.faint : colors.strong)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(colors.faint)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(colors.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(colors.lineStrong, lineWidth: 2)
                )
            }
            .menuOrder(.fixed)
            .sensoryFeedback(.selection, trigger: value)
        }
    }
}

struct OctToggle: View {
    @Environment(\.octColors) private var colors

    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .labelsHidden()
            .tint(colors.inverse)
    }
}
