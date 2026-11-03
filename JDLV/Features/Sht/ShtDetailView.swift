import SwiftUI
import JDLVCore

//
//  ShtDetailView.swift —— 帖子详情（09 D 节 ShtDetailScreen 逐字移植）。
//
//  顶栏（D1）：标题「帖子详情」（1 行省略，不显示帖子标题）+「Aa」TextButton（14 Bold，
//  打开阅读设置弹层）+ 收藏 icon（双态 tint）。返回用系统导航返回（对位「返回」icon）。
//
//  页面状态（D2）：loading → LoadingBox；error → ErrorBox(error, onRetry = load)；
//  d == null → EmptyBox「远程库未收录该帖」。iOS 侧 VM 生命周期由 @StateObject 随视图
//  销毁释放（对位 Android 离开页面 release()；不挂 onDisappear —— 防压栈返回闪空）。
//
//  正文（D5 三分支）：useReaderBody → ReaderBody（阅读设置全生效）；否则 blocks 普通渲染。
//  磁力/ED2K/视频区块（D6 LinkCard）：标题逐字 + 单击复制 Toast 逐字。
//  图片贴/截图（D7）：自拍图片区通栏（宽高比 1.5）/其他帖 ThumbGrid（110pt、1.5、间距 8）
//  → 灯箱（UI/Lightbox.swift）。
//  空信息兜底（D8）：四类全空且非文学帖 → 逐字文案；末尾 30pt Spacer 收尾。
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
    }

    private var data: ShtThreadData { vm.d ?? ShtThreadData.placeholder }

    // MARK: 正文（ScrollViewReader + 进度锚点）

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
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
                    fontWeight: .bold, textAlign: .leading)
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
                        PosterImage(url: b.i ?? "", aspect: 1.5)
                    } else if b.isText {
                        AppText(b.t ?? " ", lvl: .bodyS,
                                fontWeight: b.isBold ? .bold : nil, textAlign: .leading)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: 磁力 / ED2K / 视频区块（D6 LinkCard）

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

    /// 磁力卡：主行 link（等宽 12sp 最多 2 行省略）+ 次行 name.take(46) ·「N 个文件」+ 角标 fmtSize
    private func magnetCard(_ m: ShtMagnet) -> some View {
        let secondary = [String(m.name.prefix(46)),
                         m.filesCount > 0 ? "\(m.filesCount) 个文件" : ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return linkCard(
            primary: m.displayLink, secondary: secondary, badge: Fmt.fmtSize(m.size),
            monospaced: true, maxPrimaryLines: 2) {
            vm.copyMagnet(m)
        }
    }

    /// LinkCard 通用卡（整卡可点复制；surface 底圆角 10）
    private func linkCard(
        primary: String, secondary: String, badge: String,
        monospaced: Bool = false, maxPrimaryLines: Int = 1,
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
                        .lineLimit(maxPrimaryLines)
                        .truncationMode(.middle)
                    if !secondary.isEmpty {
                        AppText(secondary, lvl: .meta, maxLines: 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !badge.isEmpty {
                    AppText(badge, lvl: .meta, color: theme.text2)
                }
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

    // MARK: 图片贴 / 截图（D7）→ 灯箱

    @ViewBuilder
    private var imageSections: some View {
        if data.isImagePost {
            sectionTitle("图片 (共 \(data.images.count) 张, 点击放大)")
            VStack(spacing: 8) {
                ForEach(data.images.indices, id: \.self) { i in
                    // 整帖通栏（宽满、宽高比 1.5）
                    PosterImage(url: data.images[i], aspect: 1.5, radius: 0)
                        .contentShape(Rectangle())
                        .onTapGesture { openLightbox(i) }
                }
            }
        } else if !data.images.isEmpty {
            sectionTitle("截图 (\(data.images.count) 张, 点击放大)")   // 注意：无「共」字
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 110), spacing: 8)],
                alignment: .leading, spacing: 8
            ) {
                ForEach(data.images.indices, id: \.self) { i in
                    PosterImage(url: data.images[i], aspect: 1.5)
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
        // 等首帧布局完成再滚（LazyVStack 惰性挂载）
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
