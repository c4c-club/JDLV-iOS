import SwiftUI

//
//  Controls.swift —— 小控件集（07 B7/B8/B9/B20/B21）。
//
//  - AppToggleChip：精确 36pt 高（外层 frame，内容只有水平 padding 12 —— 旧版 52 教训）、
//    圆角 8；选中 accent.opacity(0.2) 底 + 1.5pt accent 描边 + 「✓ {label}」accent Bold（Meta）；
//    未选中 theme.bg1 底 + 1pt line 描边 + label 正常（Meta）。
//  - ViewToggleButton：单按钮三态显示两态循环（1→0；2→0；0→1），显示"当前态"文案：
//    0 小图 / 1 大图 / 2 列表；圆角 8、bg1 底、1pt line 描边、h padding 10、minHeight 36；
//    图标 16pt accent + 4pt + 文案 Meta accent Medium。
//  - AppSwitchRow：整行可点（无涟漪）minHeight 48；左 label BodyS + hint Meta（top 1）；
//    右侧状态徽标（圆角 12、padding 8h/3v、Meta Medium）：开 = accent 底白字「已开启」、
//    关 = bg1 底 1pt line 描边 text2「已关闭」；徽标右侧 10pt 后原生 Switch（tint accent）。
//  - FavButton：FilledTonalIconButton 对位；Star/StarOutline；accessibilityLabel「收藏」；
//    fav 时 tint accent2（tertiary）否则默认。
//  - DropdownBox：Menu 式下拉（OutlinedButton 36pt 对位）：文案「{label}: {当前项}」
//    Meta 1 行省略；选项 BodyS。
//

// MARK: - AppToggleChip（B8）

struct AppToggleChip: View {
    let label: String
    let selected: Bool
    var onToggle: () -> Void = {}

    @Environment(\.appTheme) private var theme

    var body: some View {
        Button {
            onToggle()
        } label: {
            HStack(spacing: 0) {
                AppText(selected ? "✓ \(label)" : label, lvl: .meta,
                        color: selected ? theme.accent : theme.text,
                        fontWeight: selected ? .bold : .regular,
                        maxLines: 1)
            }
            .padding(.horizontal, 12)
            .frame(height: ComponentMetrics.chipHeight)   // 精确 36pt
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected ? theme.accent.opacity(0.2) : theme.bg1))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? theme.accent : theme.line,
                        lineWidth: selected ? 1.5 : ComponentMetrics.cardStroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)   // clickableNoRipple
    }
}

// MARK: - ViewToggleButton（B9：显示当前态，点击切到下一态）

struct ViewToggleButton: View {
    /// 0 小图 / 1 大图 / 2 列表（三档数值语义保留）
    let viewMode: Int
    var onToggle: (Int) -> Void

    @Environment(\.appTheme) private var theme

    private var label: String {
        viewMode == 1 ? AppCopy.viewLarge : (viewMode == 2 ? AppCopy.viewList : AppCopy.viewSmall)
    }
    private var icon: String {
        viewMode == 1 ? "square.grid.2x2.fill" : "square.grid.2x2"
    }

    var body: some View {
        Button {
            // 1→0；2→0；0→1（"列表"档不在页面暴露，viewMode==2 时点按钮回 0）
            onToggle(viewMode == 0 ? 1 : 0)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(theme.accent)
                AppText(label, lvl: .meta, color: theme.accent, fontWeight: .medium, maxLines: 1)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: ComponentMetrics.chipHeight)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.bg1))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(theme.line, lineWidth: ComponentMetrics.cardStroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AppSwitchRow（B7：文字徽标 + Toggle，整行点击即切换）

struct AppSwitchRow: View {
    let label: String
    let checked: Bool
    var hint: String = ""
    var onChange: (Bool) -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        Button {
            onChange(!checked)
        } label: {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    AppText(label, lvl: .bodyS)
                    if !hint.isEmpty {
                        AppText(hint, lvl: .meta)
                    }
                }
                Spacer(minLength: 8)
                badge
                    .padding(.trailing, 10)
                Toggle("", isOn: Binding(get: { checked }, set: { onChange($0) }))
                    .labelsHidden()
                    .tint(theme.accent)
                    .fixedSize()
            }
            .padding(.vertical, 2)
            .frame(minHeight: ComponentMetrics.buttonMin, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 状态徽标（两态文案逐字「已开启 / 已关闭」；开 = accent 底白字、关 = bg1 底 text2）
    private var badge: some View {
        AppText(checked ? AppCopy.switchOnBadge : AppCopy.switchOffBadge,
                lvl: .meta, color: checked ? .white : theme.text2,
                fontWeight: .medium, maxLines: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(checked ? theme.accent : theme.bg1))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(checked ? Color.clear : theme.line,
                        lineWidth: ComponentMetrics.cardStroke))
    }
}

// MARK: - FavButton（B20）

struct FavButton: View {
    let fav: Bool
    var onToggle: () -> Void = {}

    @Environment(\.appTheme) private var theme

    var body: some View {
        Button {
            onToggle()
        } label: {
            Image(systemName: fav ? "star.fill" : "star")
                .font(.system(size: 18))
                .foregroundColor(fav ? theme.accent2 : theme.text2)
                .frame(width: 40, height: 40)
                .background(Circle().fill(theme.accent.opacity(0.15)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("收藏")
    }
}

// MARK: - DropdownBox（B21：Menu 式下拉，按钮 36pt）

struct DropdownOption: Identifiable, Equatable {
    let label: String
    let value: String
    var id: String { value }
}

struct DropdownBox: View {
    let label: String
    let options: [DropdownOption]
    /// 当前选中值（value）
    let current: String
    var enabled: Bool = true
    var onSelect: (String) -> Void

    @Environment(\.appTheme) private var theme

    private var currentLabel: String {
        options.first { $0.value == current }?.label ?? current
    }

    var body: some View {
        Menu {
            ForEach(options) { opt in
                Button(opt.label) { onSelect(opt.value) }
            }
        } label: {
            HStack(spacing: 0) {
                AppText("\(label): \(currentLabel)", lvl: .meta, maxLines: 1)
            }
            .padding(.horizontal, 10)
            .frame(height: ComponentMetrics.dropdownHeight)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.bg1))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(theme.line, lineWidth: ComponentMetrics.cardStroke))
            .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .frame(height: ComponentMetrics.dropdownHeight)
    }
}
