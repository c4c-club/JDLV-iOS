import SwiftUI
import JDLVCore

//
//  ShtDetailView.swift —— 帖子详情（09 D 节 ShtDetailScreen 对位 + 13 §4.7 设计系统 v2）。
//
//  v2 结构（问题 10 修复）：
//  - 容器：单 ScrollView + 单 LazyVStack（PageScaffold 四态直挂；ReaderBody 已改普通
//    VStack，不再多层 lazy 嵌套）。
//  - 解析：ShtThreadData.parse 多形态（blocks [[String:Any]]/JSON String/[String]；
//    images [String]/[[String:Any]]；magnets 字典/裸链；article 纯文本分段；HTML entity）。
//  - 正文：Text+AttributedString（textSelection）；磁力/ED2K/视频卡 lineLimit(nil)
//    + textSelection + 复制按钮（不再 2 行截断）；图片 AspectImage(fit) 全宽。
//  - 顶栏（D1）：标题「帖子详情」+ Aa + 收藏。灯箱 fullScreenCover。
//

// MARK: - ShtDetailView

struct ShtDetailView: View {
    let tid: String

    @StateObject private var vm: ShtDetailVM
    @StateObject private var rs: ReaderStyleStore

    @EnvironmentObject private var store: SettingsStore
    @Environment(\.appTheme) private var theme

    @State private var showReaderSheet = false
    @State private var lightbox: LightboxState? = nil
    @State private var visibleBlock: Int? = nil
    @State private var progressRestored = false

    init(tid: String) {
        self.tid = tid
        _vm = StateObject(wrappedValue: ShtDetailVM(tid: tid))
        _rs = StateObject(wrappedValue: ReaderStyleStore())
    }

    var body: some View {
        Group {
            if vm.loading && vm.d == nil {
                LoadingBox()
            } else if let e = vm.error, vm.d == nil {
                ErrorBox(text: e, onRetry: { Task { await vm.load(tid) } })
            } else if vm.d == nil {
                EmptyBox(text: "远程库未收录该帖")
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg0.ignoresSafeArea())
        .navigationTitle("帖子详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showReaderSheet = true
                } label: {
                    Text("Aa")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(theme.accent)
                }
                .accessibilityIdentifier("sht_reader_aa")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                FavButton(fav: vm.fav) { vm.toggleFav(tid) }
            }
        }
        .sheet(isPresented: $showReaderSheet) {
            ReaderStyleSheet(rs: rs)
        }
        .fullScreenCover(item: $lightbox) { lb in
            Lightbox(urls: lb.urls, initialIndex: lb.index) { lightbox = nil }
        }
        .onAppear {
            rs.attach(store)   // rd_* 回读（首 attach 后不再覆盖会话内修改）
            if vm.d == nil && vm.error == nil && !vm.loading {
                Task { await vm.load(tid) }
            }
        }
        .accessibilityIdentifier("sht_detail_page")
    }

    private var data: ShtThreadData { vm.d ?? ShtThreadData.placeholder }

    // MARK: 正文（单 ScrollView + 单 LazyVStack + 进度锚点）

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    titleBlock
                        .padding(.bottom, 10)
                    readerOrPlain
                    linkSections
                    imageSections
                    if data.needsEmptyFallback {
                        emptyFallback
                    }
                    Color.clear.frame(height: 30)   // 末尾 30dp Spacer 收尾（D8）
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .id("sht_detail_top")
            }
            .onAppear { restoreProgress(proxy) }
            .onDisappear {
                // 阅读位置保持（滚动锚点）：存顶层可见段索引
                if let v = visibleBlock { ReaderProgress.save(tid: tid, blockIndex: v) }
            }
        }
    }

    /// 标题（Bold 16、行高 22）+ 元信息行（board_name · post_date，12sp）（D4）
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            AppText(data.title.isEmpty ? " " : data.title, lvl: .titleM,
                    textAlign: .leading, fontWeight: .bold)
            if !data.metaLine.isEmpty {
                AppText(data.metaLine, lvl: .meta)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 正文三分支（D5）：ReaderBody（小说阅读器）/ blocks 普通渲染 / 无 blocks 不渲染
    @ViewBuilder
    private var readerOrPlain: some View {
        if data.useReaderBody {
            ReaderBody(
                style: rs.style,
                blocks: data.blocks,
                progressTid: tid,
                onVisibleChange: { v in visibleBlock = v })
        } else if !data.blocks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(data.blocks.indices, id: \.self) { i in
                    let b = data.blocks[i]
                    if b.isImage {
                        AspectImage(url: b.i ?? "", ratio: 1.5, fill: false)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let urls = data.blocks.compactMap { $0.isImage ? $0.i : nil }
                                if let u = b.i, let idx = urls.firstIndex(of: u) {
                                    lightbox = LightboxState(urls: urls, index: idx)
                                }
                            }
                    } else if b.isText {
                        textParagraph(b.t ?? " ", bold: b.isBold)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// 正文段落（textSelection + 粗体；13 §4.7）
    private func textParagraph(_ text: String, bold: Bool) -> some View {
        Text(text)
            .font(.system(size: 13))
            .fontWeight(bold ? .bold : .regular)
            .foregroundColor(theme.text)
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 磁力 / ED2K / 视频区块（D6 LinkCard；v2 长链接不截断）

    @ViewBuilder
    private var linkSections: some View {
        if !data.magnets.isEmpty {
            sectionTitle("磁力链接 (共 \(data.magnets.count) 条, 单击复制)")
            ForEach(data.magnets.indices, id: \.self) { i in
                magnetCard(data.magnets[i])
            }
        }
        if !data.ed2k.isEmpty {
            sectionTitle("ED2K (共 \(data.ed2k.count) 条, 单击复制)")
            ForEach(data.ed2k.indices, id: \.self) { i in
                let e = data.ed2k[i]
                linkCard(primary: e.url, secondary: "", badge: Fmt.fmtSize(e.size)) {
                    vm.copyEd2k(e)
                }
            }
        }
        if !data.videos.isEmpty {
            sectionTitle("视频直链 (共 \(data.videos.count) 条, 单击复制)")
            ForEach(data.videos.indices, id: \.self) { i in
                let url = data.videos[i]
                linkCard(primary: url, secondary: "", badge: "") {
                    vm.copyVideo(url)
                }
            }
        }
    }

    /// 磁力卡：主行 link（不截断、可选中）+ 次行 name ·「N 个文件」+ 角标 fmtSize + 复制按钮
    private func magnetCard(_ m: ShtMagnet) -> some View {
        let secondary = [m.name.isEmpty ? nil : m.name,
                         m.filesCount > 0 ? "\(m.filesCount) 个文件" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
        return linkCard(
            primary: m.displayLink, secondary: secondary, badge: Fmt.fmtSize(m.size),
            monospaced: true) {
            vm.copyMagnet(m)
        }
    }

    /// LinkCard 通用卡（v2：主行 lineLimit(nil) + textSelection；整卡可点复制 + 显式复制钮）
    private func linkCard(
        primary: String, secondary: String, badge: String,
        monospaced: Bool = false,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(primary)
                        .font(monospaced
                              ? .system(size: 12, weight: .regular, design: .monospaced)
                              : .system(size: 12))
                        .foregroundColor(theme.text)
                        .lineLimit(nil)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if !secondary.isEmpty {
                        AppText(secondary, lvl: .meta, maxLines: 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !badge.isEmpty {
                    AppText(badge, lvl: .meta, color: theme.text2)
                }
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 14))
                    .foregroundColor(theme.accent)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: ComponentMetrics.imageCorner)
                .fill(theme.bg1))
            .overlay(RoundedRectangle(cornerRadius: ComponentMetrics.imageCorner)
                .stroke(theme.line, lineWidth: ComponentMetrics.cardStroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 6)
    }

    private func sectionTitle(_ text: String) -> some View {
        AppText(text, lvl: .bodyS, fontWeight: .bold)   // Bold 14sp
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 图片贴 / 截图（D7；v2 AspectImage fit 全宽）→ 灯箱

    @ViewBuilder
    private var imageSections: some View {
        if data.isImagePost {
            sectionTitle("图片 (共 \(data.images.count) 张, 点击放大)")
            VStack(spacing: 8) {
                ForEach(data.images.indices, id: \.self) { i in
                    // 整帖通栏（宽满、宽高比 1.5、fit 不裁切）
                    AspectImage(url: data.images[i], ratio: 1.5, fill: false, radius: 0)
                        .contentShape(Rectangle())
                        .onTapGesture { openLightbox(i) }
                }
            }
        } else if !data.images.isEmpty {
            sectionTitle("截图 (\(data.images.count) 张, 点击放大)")   // 注意：无「共」字
            VStack(spacing: 8) {
                ForEach(data.images.indices, id: \.self) { i in
                    AspectImage(url: data.images[i], ratio: 1.5, fill: false)
                        .contentShape(Rectangle())
                        .onTapGesture { openLightbox(i) }
                }
            }
        }
    }

    private func openLightbox(_ index: Int) {
        lightbox = LightboxState(urls: data.images, index: index)
    }

    // MARK: 空信息兜底（D8）

    private var emptyFallback: some View {
        AppText("该帖在远程库只有标题等基础信息 — 磁力/图片明细需抓取端上传",
                lvl: .meta)   // 12sp onSurfaceVariant；长破折号 —
            .padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 阅读位置保持（滚动锚点恢复）

    private func restoreProgress(_ proxy: ScrollViewProxy) {
        guard !progressRestored, data.useReaderBody,
              let a = ReaderProgress.load(tid: tid), a > 0 else { return }
        progressRestored = true
        // 等首帧布局完成再滚
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            proxy.scrollTo("rd_blk_\(a)", anchor: .top)
        }
    }
}

// MARK: - 灯箱载荷（Identifiable 供 fullScreenCover(item:)）

struct LightboxState: Identifiable {
    let urls: [String]
    let index: Int
    var id: String { "\(index)-\(urls.count)-\(urls.first ?? "")" }
}

// MARK: - 解析占位（d 尚未就绪时避免强制解包）

extension ShtThreadData {
    static let placeholder = ShtThreadData(
        tid: "", title: "", boardName: "", postDate: "", catName: "", words: 0)
}
