import SwiftUI
import JDLVCore

//
//  FiltersPanel.swift —— 浏览页筛选面板（08 A.3 BrowseFilterPanel 逐字移植）。
//
//  形态：FilterDropdown 顶部下拉弹层（非 BottomSheet）；面板只在展开时 compose
//  （每次打开分区开合/关键字/局部展开态都是初始态）；内容 = 单一 ScrollView+LazyVStack
//  （对位 Android「单一 LazyColumn」铁律），最大高度 = 屏高 × 0.62（FilterDropdown 容器）。
//
//  分区开合：CollapsibleSection（UI/Common）+ storageKey 本地折叠记忆（FD.keyPrefix =
//  jdlv_collapse_）；默认全收起；「展开全部/全部收起」写全量记忆键后重挂载。
//  输关键字自动展开（A.3）：codeQuery→番号、makerQuery→片商、st.tagQuery→分类标签 ——
//  CollapsibleSection 自持状态不可编程展开，故自动展开期间 storageKey 置 nil +
//  initiallyExpanded=true + .id() 重挂载（记忆在查询清空后恢复）。
//
//  常用/全部切换（P9b 任务 D）：番号 2000 / 片商 500 / 标签 500 阈值（本地面板态；
//  标签走 VM.tagMode：常用且关键字空 → take(200)，全部或有关键字 → 全量 ≤500）。
//  每区超限显示 60 个 chip + 「展开更多（还有 {n} 项）」（全角括号）/「收起」；
//  索引未到位显示骨架条（3 根 24pt 高圆角灰条）。
//
//  逐字文案核对表见文末（含全角/半角差异）。
//

// MARK: - 流式布局（iOS 16 Layout 协议对位 Android FlowRow）

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > maxW {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        let w = proposal.width ?? max(0, x - spacing)
        return CGSize(width: w, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x - bounds.minX + sz.width > bounds.width {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            s.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

// MARK: - 紧凑过滤输入框（32pt、圆角 8、surfaceVariant 底）

private struct CompactFilterField: View {
    let placeholder: String
    @Binding var text: String

    @Environment(\.appTheme) private var theme

    var body: some View {
        TextField(placeholder, text: $text)
            .font(.system(size: 13))
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(.horizontal, 8)
            .frame(minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.bg3))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
    }
}

// MARK: - 骨架条（索引未到位：3 根 24pt 高圆角灰条）

private struct FilterSkeletonBars: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.bg3)
                    .frame(height: 24)
            }
        }
    }
}

// MARK: - FiltersPanel

struct FiltersPanel: View {
    @ObservedObject var vm: BrowseVM
    var onDone: () -> Void

    @Environment(\.appTheme) private var theme

    // 番号/片商 常用/全部阈值（P9b 任务 D；标签阈值 500 = taxonomy 远程上限）
    static let codeCommonCap = 2000
    static let makerCommonCap = 500
    /// 标签「常用」口径（08 A.3：tagMode=common 且关键字空 → take(200)）
    static let tagCommonCap = 200
    /// 每区超限限量
    static let chipPage = 60

    // 面板本地态（面板只在展开时 compose → 每次打开重置）
    @State private var codeQuery = ""
    @State private var makerQuery = ""
    @State private var codesAll = false        // 番号 常用(false)/全部(true)
    @State private var makersAll = false       // 片商 常用/全部
    @State private var codesExpanded = false
    @State private var makersExpanded = false
    @State private var tagsExpanded = false
    /// 「展开全部/全部收起」写全量记忆键后重挂载分区（tick 变化 → .id() 重建）
    @State private var sectionTick = 0

    // 分区 storageKey（折叠记忆；键 = jdlv_collapse_{key}）
    private static let keys = ["time", "code", "maker", "tag", "switch"]
    private static let titles = ["time": "时间", "code": "番号", "maker": "片商",
                                 "tag": "分类标签", "switch": "开关 / 每页"]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                sourceRow              // 第 0 行：索引来源 + 展开全部/全部收起 + 重试
                section(key: "time", autoOpen: false) { timeSection }
                section(key: "code", autoOpen: !codeQuery.isEmpty) { codeSection }
                section(key: "maker", autoOpen: !makerQuery.isEmpty) { makerSection }
                section(key: "tag", autoOpen: !vm.tagQuery.isEmpty) { tagSection }
                section(key: "switch", autoOpen: false) { switchSection }
                bottomRow
            }
        }
    }

    // MARK: 第 0 行（索引来源行 + 全局按钮）

    private var indexLoading: Bool {
        vm.filterSource == "loading" || (vm.codes.isEmpty && vm.makers.isEmpty && vm.tags.isEmpty)
    }

    /// 来源文案（st.filterSource 四态 + loading 判定，A.3 逐字；ts≤0 → 时间空串）
    private var sourceLine: String {
        if indexLoading { return "索引加载中…" }
        switch vm.filterSource {
        case "remote":
            return "索引来源：远程库 · 更新于 \(Fmt.fmtTime(vm.taxonomyTs))"
        case "fallback":
            return "远程索引表为空（已回退近似值） · 更新于 \(Fmt.fmtTime(vm.taxonomyTs))"
        case "stale":
            return "本地缓存索引（可能过期）"
        default:   // assets
            return "本地静态索引（可能不全）"
        }
    }

    private var sourceRow: some View {
        HStack(spacing: 8) {
            AppText(sourceLine, lvl: .meta)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                expandAll(true)
            } label: {
                AppText("展开全部", lvl: .meta, color: theme.accent)
                    .frame(minHeight: ComponentMetrics.touchMin)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                expandAll(false)
            } label: {
                AppText("全部收起", lvl: .meta, color: theme.accent)
                    .frame(minHeight: ComponentMetrics.touchMin)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                Task { await vm.reload() }   // A.3 逐字：重试 → vm2.reload(force=false)
            } label: {
                AppText("重试", lvl: .meta, color: theme.accent)
                    .frame(minHeight: ComponentMetrics.touchMin)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    /// 展开全部/全部收起：写全量折叠记忆键 + 重挂载
    private func expandAll(_ open: Bool) {
        let d = UserDefaults.standard
        for k in Self.keys {
            d.set(open, forKey: FD.keyPrefix + k)
        }
        sectionTick += 1
    }

    // MARK: 分区容器（折叠记忆 + 关键字自动展开）

    @ViewBuilder
    private func section<Content: View>(
        key: String, autoOpen: Bool, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        CollapsibleSection(
            title: Self.titles[key] ?? key,
            storageKey: autoOpen ? nil : key,          // 自动展开期间不读不写记忆
            initiallyExpanded: autoOpen,
            content: content)
        .id("\(key)|\(sectionTick)|\(autoOpen)")
    }

    /// 分区内容外框（SectionBody = Card 描边内 12pt padding）
    private func sectionBody<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(theme.bg0.opacity(0.4)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
    }

    // MARK: 分区 1「时间」

    private var yearOptions: [DropdownOption] {
        [DropdownOption(label: "全部", value: "")] +
            vm.years.map { DropdownOption(label: $0.s("year"), value: $0.s("year")) }
    }

    private var monthOptions: [DropdownOption] {
        [DropdownOption(label: "全部", value: "")] +
            (1...12).map { DropdownOption(label: "\($0)", value: "\($0)") }   // 无补零
    }

    private var timeSection: some View {
        sectionBody {
            VStack(alignment: .leading, spacing: 8) {
                DropdownBox(label: "年份", options: yearOptions, current: vm.f.year) { v in
                    Task { await vm.setFilter { $0.year = v } }
                }
                DropdownBox(label: "月份", options: monthOptions, current: vm.f.month) { v in
                    Task { await vm.setFilter { $0.month = v } }
                }
            }
        }
    }

    // MARK: 分区 2「番号」（codes 全量索引 + 关键字过滤）

    /// 常用/全部阈值裁剪 + 关键字过滤
    private var filteredCodes: [Row] {
        let base = codesAll ? vm.codes : Array(vm.codes.prefix(Self.codeCommonCap))
        let q = codeQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { $0.s("name").lowercased().contains(q) }
    }

    private var shownCodes: [Row] {
        codesExpanded ? filteredCodes : Array(filteredCodes.prefix(Self.chipPage))
    }

    private var codeSection: some View {
        sectionBody {
            VStack(alignment: .leading, spacing: 8) {
                CompactFilterField(placeholder: "输入字头过滤, 如 abp", text: $codeQuery)
                if vm.codes.isEmpty {
                    FilterSkeletonBars()
                } else {
                    commonAllChips(all: codesAll) { codesAll.toggle() }
                    FlowLayout(spacing: 8) {
                        // 首 chip「全部」：选中态 = letter 为空；点击清 letter（单选）
                        AppToggleChip(label: "全部", selected: vm.f.letter.isEmpty) {
                            Task { await vm.setFilter { $0.letter = "" } }
                        }
                        ForEach(shownCodes.indices, id: \.self) { i in
                            let c = shownCodes[i]
                            AppToggleChip(
                                label: "\(c.s("name")) (\(c.i("c")))",
                                selected: vm.f.letter == c.s("name")) {
                                Task { await vm.setFilter { $0.letter = c.s("name") } }
                            }
                        }
                    }
                    expandMore(count: filteredCodes.count, expanded: $codesExpanded)
                }
            }
        }
    }

    // MARK: 分区 3「片商」（makers 全量 + 关键字过滤；选中态按 id 匹配）

    private var filteredMakers: [Row] {
        let base = makersAll ? vm.makers : Array(vm.makers.prefix(Self.makerCommonCap))
        let q = makerQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter {
            let name = $0.s("name")
            let target = name.isEmpty ? "#\($0.s("id"))" : name
            return target.lowercased().contains(q) || $0.s("id").lowercased().contains(q)
        }
    }

    private var shownMakers: [Row] {
        makersExpanded ? filteredMakers : Array(filteredMakers.prefix(Self.chipPage))
    }

    private var makerSection: some View {
        sectionBody {
            VStack(alignment: .leading, spacing: 8) {
                CompactFilterField(placeholder: "输入片商名过滤", text: $makerQuery)
                if vm.makers.isEmpty {
                    FilterSkeletonBars()
                } else {
                    commonAllChips(all: makersAll) { makersAll.toggle() }
                    FlowLayout(spacing: 8) {
                        AppToggleChip(label: "全部", selected: vm.f.maker.isEmpty) {
                            Task { await vm.setFilter { $0.maker = "" } }
                        }
                        ForEach(shownMakers.indices, id: \.self) { i in
                            let m = shownMakers[i]
                            // name 为空显示 #{id}；选中态按 id 匹配
                            AppToggleChip(
                                label: m.s("name").isEmpty ? "#\(m.s("id"))" : m.s("name"),
                                selected: vm.f.maker == m.s("id")) {
                                Task { await vm.setFilter { $0.maker = m.s("id") } }
                            }
                        }
                    }
                    expandMore(count: filteredMakers.count, expanded: $makersExpanded)
                }
            }
        }
    }

    // MARK: 分区 4「分类标签」（7 组内置分类拍平展示：主題/角色/服裝/體型/行爲/玩法/類別）

    /// tagMode 口径（A.3）：common 且关键字空 → 前 200；all 或有关键字 → 全量（≤500）
    private var filteredTags: [Row] {
        var base = (vm.tagMode == "common" && vm.tagQuery.isEmpty)
            ? Array(vm.tags.prefix(Self.tagCommonCap))
            : vm.tags
        let q = vm.tagQuery.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            base = base.filter { $0.s("name").lowercased().contains(q) }
        }
        return base
    }

    private var shownTags: [Row] {
        tagsExpanded ? filteredTags : Array(filteredTags.prefix(Self.chipPage))
    }

    /// 选中态 = tag_id 在 f.tags 逗号集合内（多选）
    private func tagSelected(_ id: String) -> Bool {
        vm.f.tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .contains(id)
    }

    private var tagSection: some View {
        sectionBody {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    AppToggleChip(label: "常用", selected: vm.tagMode == "common") {
                        vm.setTagMode("common")
                    }
                    AppToggleChip(label: "全部", selected: vm.tagMode == "all") {
                        vm.setTagMode("all")
                    }
                }
                CompactFilterField(
                    placeholder: "输入标签关键字过滤",
                    text: Binding(get: { vm.tagQuery }, set: { vm.setTagQuery($0) }))
                if vm.tags.isEmpty {
                    // 空态说明（非骨架条，12pt onSurfaceVariant）
                    AppText("标签来自内置索引，联网后自动补全", lvl: .meta)
                } else {
                    FlowLayout(spacing: 8) {
                        ForEach(shownTags.indices, id: \.self) { i in
                            let t = shownTags[i]
                            AppToggleChip(
                                label: "\(t.s("name")) (\(t.i("c")))",
                                selected: tagSelected(t.s("id"))) {
                                Task { await vm.toggleTag(t.s("id")) }
                            }
                        }
                    }
                    expandMore(count: filteredTags.count, expanded: $tagsExpanded)
                }
            }
        }
    }

    // MARK: 分区 5「开关 / 每页」

    private var perOptions: [DropdownOption] {
        ["20", "40", "60", "80", "100"].map { DropdownOption(label: $0, value: $0) }
    }

    private var switchSection: some View {
        sectionBody {
            VStack(alignment: .leading, spacing: 8) {
                // 4 个开关 chip（多选独立）；⚠ 面板「中文字幕」≠反查摘要「中字」
                FlowLayout(spacing: 8) {
                    AppToggleChip(label: "有磁力", selected: vm.f.magnet) {
                        Task { await vm.toggleMagnet() }
                    }
                    AppToggleChip(label: "中文字幕", selected: vm.f.cnsub) {
                        Task { await vm.toggleCnsub() }
                    }
                    AppToggleChip(label: "可播放", selected: vm.f.canPlay) {
                        Task { await vm.toggleCanPlay() }
                    }
                    AppToggleChip(label: "单体", selected: vm.f.single) {
                        Task { await vm.toggleSingle() }
                    }
                }
                DropdownBox(label: "每页", options: perOptions, current: "\(vm.per)") { v in
                    if let p = Int(v) {
                        Task { await vm.setPer(p) }
                    }
                }
            }
        }
    }

    // MARK: 常用/全部 chips（番号/片商；单选）

    private func commonAllChips(all: Bool, onToggle: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            AppToggleChip(label: "常用", selected: !all, onToggle: onToggle)
            AppToggleChip(label: "全部", selected: all, onToggle: onToggle)
        }
    }

    // MARK: 展开更多（前 60 + 全角括号计数 / 收起）

    @ViewBuilder
    private func expandMore(count: Int, expanded: Binding<Bool>) -> some View {
        if count > Self.chipPage {
            Button {
                expanded.wrappedValue.toggle()
            } label: {
                AppText(
                    expanded.wrappedValue
                        ? "收起"
                        : "展开更多（还有 \(count - Self.chipPage) 项）",
                    lvl: .meta, color: theme.accent)
                    .frame(minHeight: ComponentMetrics.touchMin, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 底部操作行（右对齐；底部垫 navigationBarsPadding + 16）

    private var bottomRow: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                Task { await vm.clearFilters() }
            } label: {
                AppText("重置全部", lvl: .bodyS, color: theme.accent)
                    .frame(minHeight: ComponentMetrics.buttonMin)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                onDone()
            } label: {
                AppText("完成", lvl: .bodyS, color: .white, fontWeight: .medium)
                    .padding(.horizontal, 20)
                    .frame(minHeight: ComponentMetrics.buttonMin)
                    .background(RoundedRectangle(cornerRadius: 12).fill(theme.accent))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }
}

// MARK: - 逐字文案核对（08 A.3，全部内联于上）
//
// | 位置 | 文案 |
// |---|---|
// | 来源行 | 索引加载中… / 索引来源：远程库 · 更新于 {HH:mm} / 远程索引表为空（已回退近似值） · 更新于 {HH:mm} / 本地缓存索引（可能过期） / 本地静态索引（可能不全） |
// | 第 0 行按钮 | 展开全部 / 全部收起 / 重试 |
// | 分区标题 | 时间 / 番号 / 片商 / 分类标签 / 开关 / 每页 |
// | 时间区 | 年份 / 月份 / 全部（1..12 不补零） |
// | 番号区 | 输入字头过滤, 如 abp（半角逗号+空格）/ 全部 / {name} ({c}) / 展开更多（还有 {n} 项）/ 收起 |
// | 片商区 | 输入片商名过滤 / 全部 / #{id}（空名） |
// | 标签区 | 常用 / 全部 / 输入标签关键字过滤 / 标签来自内置索引，联网后自动补全 / {name} ({c}) |
// | 开关区 | 有磁力 / 中文字幕 / 可播放 / 单体 / 每页 / 20 40 60 80 100 |
// | 底部 | 重置全部 / 完成 |
