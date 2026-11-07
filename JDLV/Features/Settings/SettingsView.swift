//
//  SettingsView.swift
//  JDLV
//
//  P12：设置页全量（docs/_extract/11_settings.md 移植；SettingsScreen.kt 对位）。
//
//  口径（11_settings §0）：
//  - 布局：ScrollView + padding 16 + 顶部保存状态行 + 11 张 SettingsGroupCard 卡 + Spacer(30)；
//    注释自述（逐字）：`设置页 (★ P9.4, 2026-10-31 重排): 分区 ①数据源 ②网络与代理 ③图床
//    (jdb + 98t) ④外观与启动锁 ⑤浏览与搜索 ⑥语义搜索模型 ⑦缓存与离线索引 ⑧关于 ——
//    全部自动保存; 行宽统一 (LabeledRow 96dp / DropdownRow 140dp + weight(1f) / MirrorField
//    120dp); 按钮 ≥48dp、长文案可换行; 响应式读取统一 live ?: draft。`
//  - 11 张卡默认全部收起；折叠记忆键 CollapsiblePref（UserDefaults 持久）；收起时保留一行
//    12sp 摘要；收起时内容不渲染。唯一自动展开例外：① 数据源 firstRun || user 空引导。
//  - 保存三态（0.1）：已保存 HH:mm:ss 绿 / 无变化 灰 / 保存失败 (重试或检查存储) 红 /
//    保存中… 灰；每张卡底部一行（SettingsStore.lastSaveResult 驱动）。
//  - 文本输入走 store.edit（800ms 防抖变换链）；开关/选择走 store.editNow（立即落盘）。
//  - 副作用（SettingsEffects）：dbChanged → Db.reset；cdnChanged → CdnRewrite.invalidate；
//    imgChanged → TestImages.clearCache；proxyChanged → SocksTunnel 留注释（P13）。
//  - CdnRewrite.settingsProvider 注入（线程安全快照盒 SettingsSnapshotBox 中转）。
//

import SwiftUI
import JDLVCore

// MARK: - 逐字文案集中点（11_settings.md 全部；含全角/半角标点差异）

enum SettingsCopy {

    // MARK: 0.1 保存三态（文案逐字；kind: 0=保存中 1=SAVED 2=NO_CHANGE 3=FAILED）

    static let savingText = "保存中…"
    static let noChangeText = "无变化"
    static let failedText = "保存失败 (重试或检查存储)"

    static func saveStateText(kind: Int, at: Date) -> String {
        switch kind {
        case 0: return savingText
        case 1: return "已保存 " + hhmmss(at)
        case 2: return noChangeText
        default: return failedText
        }
    }

    static func hhmmss(_ d: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df.string(from: d)
    }

    // MARK: 0.3 折叠卡标题（逐字 11 条）

    static let groupDb = "① 数据源 (改完自动保存)"
    static let groupProxy = "② 网络与代理 (数据库 / jdb 图床 / 98t 图床分开)"
    static let groupJdbImg = "③ jdb 图床 (图片直连, 毒丸自动解码)"
    static let groupShtImg = "③ 98t 图床 (输入主站地址, 保存并嗅探)"
    static let groupTheme = "④ 外观 (改即生效)"
    static let groupLock = "④ 启动锁 (打开 app 需解锁)"
    static let groupBrowse = "⑤ 浏览与搜索"
    static let groupSemantic = "⑥ 语义搜索模型"
    static let groupCache = "⑦ 缓存"
    static let groupShadow = "⑦ 离线索引 (离线可浏览/可搜索已索引内容)"
    static let groupAbout = "⑧ 关于"

    // MARK: 摘要规则（§1 表逐字模板；onOff = 开/关）

    static func onOff(_ v: Bool) -> String { v ? "开" : "关" }

    static func summaryDb(_ s: AppSettings) -> String {
        "数据源 · \(s.dbSrc) · \(s.host):\(s.port)"
    }

    static func summaryProxy(_ s: AppSettings) -> String {
        "代理 · 数据库\(onOff(s.proxyDb)) / jdb 图床\(onOff(s.proxyCdnJdb)) / 98t 图床\(onOff(s.proxyCdnSht))"
    }

    static func summaryJdbImg(_ s: AppSettings, failureRate: Int) -> String {
        "jdb 图床 · \(s.jdbImgHost) · 失败率 \(failureRate)%"
    }

    static func summaryShtImg(live: AppSettings, draft: AppSettings) -> String {
        let h = live.shtMirrorHost.isEmpty ? draft.shtMirrorHost : live.shtMirrorHost
        return "98t 图床 · \(h.isEmpty ? "未嗅探" : h)"
    }

    static func summaryTheme(_ s: AppSettings) -> String {
        "主题 · \(s.themeName) · 强调色 \(s.themeAccent)"
    }

    static func summaryLock(_ s: AppSettings) -> String {
        s.lockEnabled ? "已启用 · \(s.lockType)" : "未启用"
    }

    static func summaryBrowse(_ s: AppSettings) -> String {
        "视图 \(s.viewMode) · 每页 \(s.perPage) · 98t 每页 \(s.shtPer)"
    }

    static func summarySemantic(installed: Bool) -> String {
        installed ? "语义模型 · 已导入" : "语义模型 · 未导入 (语义搜索已禁用)"
    }

    static func summaryCache(_ s: AppSettings) -> String {
        "图片缓存 \(s.imageCacheMb) MB · 过期 \(s.imageCacheDays > 0 ? "\(s.imageCacheDays) 天" : "不过期")"
    }

    /// shadow 卡摘要读权威值 view（B04 修复）
    static func summaryShadow(_ s: AppSettings) -> String {
        guard s.shadowEnabled else { return "未启用" }
        return "\(s.shadowMode == 1 ? "仅索引" : "完整影子") · 影片 \(LimitMath.format(s.shadowLimitJdb)) / 帖子 \(LimitMath.format(s.shadowLimitSht)) · 女优 \(onOff(s.shadowActorIndex))"
    }

    static let summaryAbout = "JDLV Mobile · 远程库只读浏览客户端"

    // MARK: ① 数据源（§2 逐字）

    static let dsLabelSource = "当前数据源"
    static let dsLabelHost = "主机"
    static let dsLabelPort = "端口"
    static let dsLabelUser = "用户"
    static let dsLabelPass = "密码"
    static let dsLabelJdbDb = "jdb 库名"
    static let dsLabelShtDb = "98t 库名"
    static let dsPhHost = "IP / 主机名"
    static let dsPhPortLocal = "3306"
    static let dsPhPortRemote = "3307"
    static let dsPhUser = "用户名"
    static let dsPhPass = "密码"
    static let dsPhJdb = "javdb"
    static let dsPhSht = "sehuatang"
    static let dsPlain = "明文"
    static let dsHide = "隐藏"
    static let dsTlsLabel = "数据库 TLS (useSSL)"
    static let dsTlsDesc = "服务器需开启 TLS。注意: 自签名证书会跳过证书校验 —— 可防被动嗅探, 防不住主动中间人; 局域网可信环境可关闭"
    static let dsEditingOtherHint = "正在编辑另一数据源 (不影响当前连接)"
    static let dsEditOther = "编辑另一数据源…"
    static let dsBackCurrent = "返回当前数据源"
    static let dsTestIsolationNote = "测试连接直接使用上方当前填写的值（含未保存的编辑），不影响运行中的连接；正式生效仍需保存。"
    static let dsTestButton = "测试连接"
    static let dsTestingText = "测试中…"
    static let dsTestSuccessToast = "✓ 连接成功（配置保存后运行链路即生效）"
    static let dsConnTimeoutLabel = "连接超时"   // connect_timeout 档位（任务补充键, 文档无此行）

    // MARK: ② 网络与代理（§3 逐字）

    static let proxyHostLabel = "代理主机"
    static let proxyPortLabel = "代理端口"
    static let proxyHostPh = "127.0.0.1"
    static let proxyPortPh = "7890"
    static let proxyPortNote = "Clash 等混合端口一般 7890；数据库走 SOCKS，图片走 HTTP"
    static let proxyDbLabel = "数据库走代理 (SOCKS5)"
    static let proxyDbDesc = "MySQL 原生协议, 走 SOCKS (Clash 混合端口同样支持)"
    static let proxyJdbLabel = "jdb 图床走代理 (HTTP)"
    static let proxyJdbDesc = "jdb 图床 = 影片封面 / 剧照 / 女优头像; 关闭时直连, 失败也会自动用代理重试"
    static let proxyShtLabel = "98t 图床走代理 (HTTP)"
    static let proxyShtDesc = "98t 图床 = 论坛图片 (帖子截图/贴图); 两者可分别指定, 互不影响"
    static let proxyOverlayNote = "图床替换 (下方) 与代理可叠加使用; 代理/图床变更保存后立即生效 (无需重启)"
    static let proxyTestButton = "测试当前连接"

    // MARK: ③ jdb 图床（§4 逐字）

    static let jdbImgHostLabel = "图床选择"
    static let jdbImgApp = "app 图床 (推荐)"
    static let jdbImgWeb = "网页图床"
    static let jdbImgCustom = "自定义"
    static func jdbImgDesc(_ v: String) -> String {
        switch v {
        case "web": return "c0.jdbstatic.com/covers/..."
        case "custom": return "填入镜像域名, spfcas 系自动带 /rhe951l4q 前缀"
        default: return "tp.spfcas.com/rhe951l4q/covers/... (风控最宽松)"
        }
    }
    static let jdbMirrorLabel = "镜像地址"
    static let jdbMirrorPh = "https://镜像域名 (spfcas 系自动带前缀)"
    static let jdbFixedNote = "app 图床返回的混淆字节会自动解码并验证; 解码/验证失败自动切换备用图床重试"
    static let selfTestButton = "运行图床自检"
    static let selfTestBusy = "自检中…"
    static let resetCoolingButton = "重置图片冷却"
    static let resetCoolingToast = "✓ 图片冷却已重置 (重新加载全部封面)"

    // MARK: ③ 98t 图床（§5 逐字）

    static let shtMirrorLabel = "98t 主站地址"
    static let shtMirrorPh = "当前可直达的主站, 如 ifxn.bwa09.com"
    static let shtFixedNote = "程序访问主站并打开几个最近帖子, 嗅探实际使用的图床 host,用库内真实图片验证后自动填写图床地址 (仅本地访问替换, 不修改数据库)"
    static let shtSniffButton = "保存并嗅探 98t"
    static let shtSniffingButton = "嗅探中…"
    static let shtSniffingStatus = "嗅探中… (可继续改其他设置)"
    static func shtHostStatus(_ h: String) -> String { "✓ 图床: \(h)" }
    static func shtUpdatedToast(_ h: String) -> String { "✓ 图床已更新: \(h)" }

    // MARK: ④ 外观（§6 逐字）

    static let themeLabel = "主题"
    static let themeSystem = "跟随系统"
    static let themeDark = "深色"
    static let themeLight = "浅色"
    static let themeSepia = "护眼"
    static let accentLabel = "强调色"

    // MARK: ④ 启动锁（§7 + 10 §8.8/8.9 逐字）

    static let lockTypeLabel = "锁类型"
    static let lockNone = "无"
    static let lockPin = "PIN"
    static let lockPattern = "图案"
    static let lockBiometric = "面容 ID"   // R3 问题 3：iOS 主流 Face ID（动态文案见 BiometryLabel）
    static func lockEnabledHint(_ type: String) -> String { "已启用: \(type) · 下次打开 app 生效" }
    static let pinDialogTitle = "设置启动 PIN (4-12 位数字)"
    static let pinPh1 = "输入 PIN"
    static let pinPh2 = "再次输入确认"
    static let pinErrShort = "PIN 至少 4 位"
    static let pinErrMismatch = "两次输入不一致"
    static let saveButtonText = "保存"
    static let cancelButtonText = "取消"
    static let pinSetToast = "✓ 启动 PIN 已设置"
    static let patternTitleFirst = "绘制解锁图案"
    static let patternTitleSecond = "再次绘制确认"
    static let patternHintNone = "至少连接 4 个点"
    static let patternHintFirst = "已记录第一次"
    static let patternHintErr = "两次不一致或太短 (至少 4 点), 请重画"
    static let patternSetToast = "✓ 启动图案已设置"

    // MARK: ⑤ 浏览与搜索（§8 逐字）

    static let viewModeLabel = "默认视图"
    static let viewMode0 = "小图 (右半封面)"
    static let viewMode1 = "大图 (整张)"
    static let viewMode2 = "列表 (紧凑行)"
    static let coverHalfLabel = "小图取哪半"
    static let coverHalf0 = "右半 (正面)"
    static let coverHalf1 = "左半 (背面)"
    static let coverHalf2 = "整张 (裁切居中)"
    static let lookupScopeLabel = "反查范围"
    static let lookupScope0 = "最近 2 万部内 (快)"
    static let lookupScope1 = "全库 (慢, 10s 级)"
    static let shadowPreferLabel = "离线优先 (影子库优先)"
    static let shadowPreferDesc = "开启后列表优先用本地索引, 在线也显示'本地缓存 · 可能过期'; 默认关"
    static let searchModeLabel = "搜索匹配"
    static let searchMode0 = "精确"
    static let searchMode1 = "模糊 (推荐)"
    static let perPageLabel = "每页数量"
    static let homePerLabel = "首页每段条数"
    static let shtPerLabel = "98t 每页"
    /// 语义候选说明（§8 末尾固定说明, 三段拼接; N = 当前 semCand）
    static func semCandNote(_ n: Int) -> String {
        "语义搜索只在这 \(n) 条最新帖子里找最相近的, 条数越大越准、越费流量。桌面端默认 50000 条, 手机端默认 3000 条 (只覆盖最新约 3000 帖), 搜不到时先调大这里。"
    }
    // ⑤ 追加键（11_settings.md 无对应行, 任务键清单要求; 标签为本阶段拟定）
    static let jdbSortLabel = "jdb 排序"
    static let jdbSortAscLabel = "jdb 升序"
    static let jdbSortAscDesc = "关闭 = 倒序 (默认)；开启 = 正序"
    static let actorSortLabel = "女优排序"
    static let actorGenderLabel = "女优性别"
    static let shtHasMagnetLabel = "只看有磁力"
    static let semCandLabel = "语义候选条数"

    // MARK: ⑥ 语义搜索模型（§9 逐字）

    static func semStatus(installed: Bool) -> String {
        installed ? "✓ 已导入, 语义搜索可用"
                  : "✗ 未导入 → 语义搜索已禁用 (只能用模糊)。文件在抓取端 models/minilm/ 下"
    }
    static let semStep1Idle = "① 选择 model_quantized.onnx"
    static let semStep1Done = "① 已选模型 ✓"
    static let semStep1Hint = "抓取端 models/minilm/ 目录下的模型文件 (约 115MB)"
    static let semStep2Idle = "② 选择 tokenizer.json"
    static let semStep2Done = "② 已选分词器 ✓"
    static let semStep2Hint = "同目录下的 tokenizer.json (约 16.7MB)"
    static let semStep3Idle = "③ 导入并启用"
    static let semStep3Busy = "③ 导入中…"
    static let semStep3Hint = "导入到 App 私有目录后语义搜索立即可用; 两文件都选完再点本按钮"
    static let semImportOkToast = "✓ 模型已导入, 语义搜索可用"
    static func semImportFailToast(_ err: String) -> String { "导入失败: \(err.isEmpty ? "未知错误" : err)" }
    static let semAdvancedHeader = "高级: 阈值 / 候选条数 / 向量容量 / 清空"
    static let semThresholdLabel = "语义阈值"
    static let semThreshold5 = "0.05 (宽松)"
    static let semThreshold10 = "0.10 (推荐)"
    static let semThreshold20 = "0.20 (严格)"
    static let embCacheLabel = "向量缓存容量 (改后立即生效)"
    static func embInfoLine(_ n: Int, bytes: Int64) -> String {
        "本地已缓存 \(n) 条向量 · \(String(format: "%.1f", Double(bytes) / 1_048_576.0)) MB"
    }
    static let embInfoLoading = "…"
    static let embClearButton = "清空向量缓存"
    static let embClearedInfo = "已清空 (下次语义搜索重新拉取)"
    static let embClearToast = "✓ 向量缓存已清空"

    // MARK: ⑦ 缓存（§10 逐字）

    static let homeTtlLabel = "首页缓存 (分钟)"
    static let filterTtlLabel = "筛选缓存 (分钟)"
    static let catTtlLabel = "分类缓存 (分钟)"   // cat_ttl（任务键清单; 文档 §10 无此行）
    static let imageCacheMbLabel = "图片缓存大小"
    static let imageCacheDaysLabel = "图片过期时间"
    static let imageCacheNever = "不过期"
    static let clearQueryButton = "清理查询缓存"
    static let clearQueryToast = "✓ 查询缓存已清理"
    static let sweepImageButton = "清理过期图片"
    static func sweepImageToast(_ n: Int) -> String {
        n > 0 ? "✓ 已清理 \(n) 张过期图片" : "没有过期图片"
    }

    // MARK: ⑦ 离线索引（§11 逐字）

    static let shadowEnabledLabel = "启用离线索引 (前台空闲自动预热)"
    static let shadowEnabledDesc = "在 WiFi 下分批拉取数据到本地 SQLite; 离线时浏览/搜索用本地数据兜底"
    static let shadowModeLabel = "索引模式"
    static let shadowMode1 = "仅索引 (省空间/推荐)"
    static let shadowMode0 = "完整影子 (旧)"
    static let shadowLimitJdbLabel = "jdb 容量 (部)"
    static let shadowLimitShtLabel = "98t 容量 (帖)"
    static let editLimitButtonText = "修改"
    static let shadowActorLabel = "索引女优与出演关系"
    static let shadowActorDesc = "关闭后预热只拉影片/帖子, 女优页与出演反查离线不可用"
    static let shadowTagLabel = "索引影片标签（离线标签筛选）"
    static let shadowTagDesc = "预热时顺带拉取影片↔标签关系; 关闭后离线选标签提示\"需联网\""
    static func tagEstimateText(limitJdb: Int) -> (text: String, warn: Bool) {
        let tagRows = limitJdb > 0 ? Double(limitJdb) * 5.7 : 1_008_039.0 * 5.7
        let tagMb = tagRows / 1000.0 * 0.04
        let warn = limitJdb <= 0 || limitJdb > 200_000
        var text = "标签索引预估: +\(String(format: "%.0f", tagMb)) MB (实测约 5.7 标签/片 · 0.04MB/千行)"
        if warn { text += " ⚠ 目标较大, 请确认设备空间" }
        return (text, warn)
    }
    /// 预估体积长文案（§11.3 逐字拼接）
    static func estimateText(limitJdb: Int, limitSht: Int, actorIndex: Bool) -> String {
        func estMb(_ l: Int) -> String? {
            guard l > 0 else { return nil }
            return String(format: "%.1f", 0.21 * Double(l) / 1000.0) + " MB"
        }
        let estA = estMb(limitJdb)
        let estB = estMb(limitSht)
        let estAll: String? = {
            guard let a = estA, let b = estB,
                  let av = Double(a.dropLast(3)), let bv = Double(b.dropLast(3)) else { return nil }
            return String(format: "%.1f", av + bv) + " MB"
        }()
        var text = "预估体积: 影片 \(estA ?? "不限") + 帖子 \(estB ?? "不限")"
        text += estAll != nil ? " ≈ \(estAll!)" : " ≈ 按实际行数"
        text += " (0.21 MB/千条); "
        if estAll == nil {
            text += "全量索引(影片/帖子各约 136MB)另女优约 19MB + 出演关系 30–40MB, 合计约 320–400MB; "
        }
        text += actorIndex ? "女优约 19MB (91,745 人), 出演关系按已索引影片数约 4–40MB"
                           : "女优/出演关系未启用"
        return text
    }
    static let usagePendingText = "实际占用: 统计中…"
    static func usageText(idxMb: Double, detailMb: Double) -> String {
        "实际占用(含 WAL): idx.db \(String(format: "%.1f", idxMb)) MB · 详情缓存 \(String(format: "%.1f", detailMb)) MB"
    }
    static let recalcButton = "重新统计"
    static let recalcBusyText = "统计中…"
    static func indexedLine(movies: Int64, threads: Int64, actors: Int64,
                            actorTotal: Int64, limitJdb: Int, limitSht: Int) -> String {
        func fmt(_ v: Int64) -> String { grouped(v) }
        var text = "已索引: 影片 \(fmt(movies)) / \(LimitMath.format(limitJdb)) · 帖子 \(fmt(threads)) / \(LimitMath.format(limitSht)) · 女优 \(fmt(actors)) / \(actorTotal > 0 ? fmt(actorTotal) : "—")"
        if movies < 10_000 { text += "  (本地检索暂未启用)" }
        return text
    }
    static func etaText(_ etaSec: Int64) -> String {
        guard etaSec > 0 else { return "" }
        let m = etaSec / 60
        return m >= 1 ? "预计 \(m) 分 \(etaSec % 60) 秒" : "预计 \(etaSec) 秒"
    }
    static func roundLine(phase: String, speed: Int, eta: String, note: String) -> String {
        "本轮: \(phase.isEmpty ? "idle" : phase) · \(speed) 条/分 \(eta) · \(note)"
    }
    static func lastNextLine(last: Int64, next: Int64) -> String {
        let l = last > 0 ? Fmt.fmtTime(last) : "—"
        let n = next > 0 && next != Int64.max ? Fmt.fmtTime(next) : "—"
        return "上次: \(l) · 下次自动: \(n)"
    }
    static func errorLine(_ e: String) -> String { "错误: \(e)" }
    static let rebuildTitle = "重建索引?"
    static func rebuildBody(lj: Int, ls: Int) -> String {
        "将清空本地索引并按当前上限 (\(LimitMath.format(lj)) / \(LimitMath.format(ls))) 重新预热; 详情缓存与收藏不受影响。"
    }
    static let rebuildConfirmButton = "重建"
    static let rebuildStartToast = "开始重建索引… (清空后重新预热)"
    static let rebuildStartedToast = "✓ 索引重建已启动 (后台预热中)"
    static let clearTitle = "清理离线索引?"
    static let clearBody = "将删除全部本地索引与详情缓存 (收藏/阅读进度不受影响); 离线浏览/搜索将不可用, 需重新预热。"
    static let clearConfirmButton = "清理"
    static let clearDoneToast = "✓ 离线索引已清理"
    static let limitDialogTitleJdb = "jdb 索引上限 (部)"
    static let limitDialogTitleSht = "98t 索引上限 (帖)"
    static let limitUnitWan = "万"
    static let limitUnitCount = "条"
    static let limitUnlimitedChip = "不限 (0)"
    static func limitIndexedCount(_ n: Int64) -> String { "当前已索引 \(grouped(n))" }
    static func limitRealtimeLine(n: Int64?, est: String, avail: String) -> String {
        let v = n == nil || n! <= 0 ? "不限" : grouped(n!)
        return "= \(v) 条 · \(est) · \(avail)"
    }
    static func limitEstText(n: Int64?) -> String {
        guard let n else { return "输入条数" }
        if n <= 0 { return "不限 · 按实际行数 (全库约 136MB)" }
        return "预估 \(String(format: "%.1f", 0.21 * Double(n) / 1000.0)) MB"
    }
    static let limitWarnText = "⚠ 全量索引约 320–400MB (影片+帖子+女优+出演关系), 请确认设备空间"
    static let limitInvalidText = "请输入 0 – 5,000,000 (0 = 不限)"
    static func limitTrimPreview(_ cut: Int64) -> String {
        "改小将裁剪多余 \(grouped(cut)) 条索引 (保留最新)"
    }
    static let trimConfirmTitle = "确认裁剪索引?"
    static func trimConfirmBody(current: Int64, keep: Int64) -> String {
        "将删除多余 \(grouped(current - keep)) 条索引 (按发布日期从旧到新裁剪，保留最新 \(grouped(keep)) 条), 不可恢复。"
    }
    static let trimConfirmButton = "确认裁剪"
    static let okButtonText = "确定"

    // MARK: ⑧ 关于（§12 逐字）

    static func aboutVersion(_ ver: String) -> String {
        "JDLV Mobile v\(ver) · 远程库只读浏览客户端"
    }
    static let aboutDesc = "与桌面端共用远程 MySQL; 数据源配置仅保存在本机"
    static let testImgLabel = "测试图片模式（调试）"
    static let testImgDesc = "开启后所有图片显示为本地生成的彩色测试块；仅用于截图/演示，正式使用请关闭"
    static let testImgOnToast = "✓ 测试图片模式已开启"
    static let testImgOffToast = "✓ 已恢复真图 (下拉刷新更稳)"

    // MARK: 千分位（%,d 对位；与 LimitMath 内部一致）

    static func grouped(_ v: Int64) -> String {
        let s = String(v)
        var out = ""
        var count = 0
        for ch in s.reversed() {
            if count > 0 && count % 3 == 0 { out.insert(",", at: out.startIndex) }
            out.insert(ch, at: out.startIndex)
            count += 1
        }
        return out
    }
}

// MARK: - 折叠记忆（rememberSaveable(rememberKey) 对位）

enum CollapsiblePref {
    static func key(_ k: String) -> String { "settings_fold_\(k)" }

    static func isExpanded(_ k: String, default def: Bool,
                           defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key(k)) as? Bool ?? def
    }

    static func setExpanded(_ k: String, value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key(k))
    }
}

// MARK: - 折叠卡（§0.3 CollapsibleGroupCard 对位）
//
//  注：UI\Common 已有 CollapsibleSection（B23, Browse/Actors 用），其无「收起摘要行」
//  也无卡底保存三态行挂点，且本组件禁止改动 UI\Common 内部 —— 故设置页用同视觉规格的
//  SettingsGroupCard（标题 13 Bold accent + chevron + 收起摘要 12sp 1 行 + 折叠记忆键），
//  其余 Common 组件（AppText/AppToggleChip/AppSwitchRow/DropdownOption）正常复用。

struct SettingsGroupCard<Content: View>: View {

    let title: String
    let rememberKey: String
    var defaultExpanded: Bool = false
    /// 收起时标题下一行 12sp 摘要（maxLines 1 截断）
    var summary: String = ""
    /// 卡底部保存三态行（任务 P12：每张卡底部显示 autoSave 结果）
    var bus: SaveStateBus? = nil
    @ViewBuilder let content: Content

    @State private var expanded: Bool
    @Environment(\.appTheme) private var theme

    init(title: String, rememberKey: String, defaultExpanded: Bool = false,
         summary: String = "", bus: SaveStateBus? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.rememberKey = rememberKey
        self.defaultExpanded = defaultExpanded
        self.summary = summary
        self.bus = bus
        self.content = content()
        _expanded = State(initialValue: CollapsiblePref.isExpanded(rememberKey, default: defaultExpanded))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    content
                    if let bus { SaveStateLine(bus: bus) }
                }
                .padding(.top, 8)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: ComponentMetrics.cardCorner).fill(theme.bg1))
        .overlay(RoundedRectangle(cornerRadius: ComponentMetrics.cardCorner)
            .stroke(theme.line, lineWidth: ComponentMetrics.cardStroke))
    }

    /// 头行：min 高 48、整行可点；标题 13 Bold accent；收起时摘要 12sp 1 行
    private var header: some View {
        Button {
            expanded.toggle()
            CollapsiblePref.setExpanded(rememberKey, value: expanded)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    AppText(title, lvl: .bodyS, color: theme.accent, fontWeight: .bold)
                    if !expanded {
                        AppText(summary, lvl: .meta, maxLines: 1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.accent)
            }
            .frame(minHeight: ComponentMetrics.buttonMin, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings_group_\(rememberKey)")
    }
}

// MARK: - 行控件（§0.4 规格；复用 AppText/AppToggleChip/AppSwitchRow/DropdownOption）

/// LabeledRow：label 13sp 宽 96，右侧内容等高
struct SettingsLabeledRow<Content: View>: View {
    let label: String
    var labelWidth: CGFloat = 96
    @ViewBuilder let content: Content

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            AppText(label, lvl: .bodyS, color: theme.text2)
                .frame(width: labelWidth, alignment: .leading)
            content
        }
    }
}

/// CompactField：单行 13sp、min 高 38、圆角 8、1pt 描边、surfaceVariant 35% 底
struct CompactField: View {
    @Binding var text: String
    var placeholder: String
    var secure: Bool = false
    var showPlain: Bool = true
    var keyboard: UIKeyboardType = .default
    var trailingTitle: String? = nil
    var onTrailing: (() -> Void)? = nil
    var onChanged: (String) -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if secure && !showPlain {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(.system(size: Tx.bodyS.size))
            .foregroundColor(theme.text)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: text) { onChanged($0) }

            if let t = trailingTitle, let act = onTrailing {
                Button(action: act) {
                    AppText(t, lvl: .meta, color: theme.text2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 38)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.bg3.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
    }
}

/// MirrorField：label 13sp 宽 120 + CompactField
struct MirrorField: View {
    let label: String
    @Binding var text: String
    var placeholder: String
    var onChanged: (String) -> Void

    var body: some View {
        SettingsLabeledRow(label: label, labelWidth: 120) {
            CompactField(text: $text, placeholder: placeholder, onChanged: onChanged)
        }
    }
}

/// Segmented：label 12sp onSurfaceVariant + AppToggleChip 单选（6dp 间距, 可换行）
struct SettingsSegmented: View {
    let label: String
    let options: [(label: String, value: String)]
    let current: String
    var showLabel: Bool = true
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showLabel {
                AppText(label, lvl: .meta)
            }
            WrapChips(options: options, current: current, onSelect: onSelect)
        }
    }
}

/// FlowChips：WrapLayout 中 AppToggleChip（§0.4 FlowRow 对位）
struct WrapChips: View {
    let options: [(label: String, value: String)]
    let current: String
    let onSelect: (String) -> Void

    var body: some View {
        FlowWrap(spacing: 6) {
            ForEach(options.indices, id: \.self) { i in
                AppToggleChip(label: options[i].label,
                              selected: options[i].value == current) {
                    onSelect(options[i].value)
                }
            }
        }
    }
}

/// iOS 16 Layout 协议流式布局（Android FlowRow 对位）
struct FlowWrap: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 360
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxW {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            v.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

/// DropdownRow：label 13sp 宽 140 + 值区 Menu（显示当前选项名, 无匹配显示原值, maxLines 2）
struct SettingsDropdownRow: View {
    let label: String
    let options: [DropdownOption]
    let current: String
    let onSelect: (String) -> Void

    @Environment(\.appTheme) private var theme

    private var currentLabel: String {
        options.first { $0.value == current }?.label ?? current
    }

    var body: some View {
        SettingsLabeledRow(label: label, labelWidth: 140) {
            Menu {
                ForEach(options) { opt in
                    Button(opt.label) { onSelect(opt.value) }
                }
            } label: {
                HStack(spacing: 4) {
                    AppText(currentLabel, lvl: .bodyS, maxLines: 2, textAlign: .leading)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11))
                        .foregroundColor(theme.text2)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: ComponentMetrics.dropdownHeight)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.bg1))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.line, lineWidth: ComponentMetrics.cardStroke))
                .contentShape(Rectangle())
            }
        }
    }
}

/// FilledTonalButton 对位（min 48dp；busy 时禁用并显示 busy 文案）
struct SettingsActionButton: View {
    let title: String
    var busyTitle: String? = nil
    var busy: Bool = false
    var enabled: Bool = true
    var filled: Bool = false
    var minHeight: CGFloat = ComponentMetrics.buttonMin
    var id: String? = nil
    let action: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            AppText(busy ? (busyTitle ?? title) : title, lvl: .bodyS,
                    color: fg, maxLines: 1, fontWeight: .medium)
                .frame(maxWidth: .infinity)
                .frame(minHeight: minHeight)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(filled ? theme.accent : theme.accent.opacity(0.2)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy || !enabled)
        .opacity(busy || !enabled ? 0.55 : 1)
        .accessibilityIdentifier(id ?? "")
    }

    private var fg: Color { filled ? .white : theme.accent }
}

/// TextButton 对位（12sp、min 高 48）
struct SettingsTextButton: View {
    let title: String
    var minHeight: CGFloat = ComponentMetrics.buttonMin
    let action: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            AppText(title, lvl: .meta, color: theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: minHeight, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 说明文字（12sp meta；长文案换行）
struct SettingsNote: View {
    let text: String
    var topPad: CGFloat = 0
    var color: Color? = nil

    var body: some View {
        AppText(text, lvl: .meta, color: color, textAlign: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, topPad)
    }
}

// MARK: - 设置页主容器

struct SettingsView: View {

    /// 首启引导路径（① 数据源自动展开用；AppGate setup 分支嵌入）
    var firstRun: Bool = false

    @EnvironmentObject private var store: SettingsStore
    @Environment(\.appTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let s = store.settings
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // 全局唯一保存状态行（R3 问题 4：单一 SaveStatusView；各卡不再挂）
                SaveStatusView(state: store.saveState,
                               onRetry: { Task { await store.flushPendingEdits() } })
                DataSourceCard(firstRun: firstRun)
                ProxyCard()
                JdbImageCard()
                ShtImageCard()
                ThemeCard()
                LockCard()
                BrowseSearchCard()
                SemanticModelCard()
                CacheCard()
                OfflineIndexCard()
                aboutLink
                Spacer().frame(height: 30)
            }
            .padding(16)
        }
        .background(theme.bg0.ignoresSafeArea())
        .accessibilityIdentifier("settings_page")
        .onAppear {
            SettingsIndexHub.shared.box.update(s)
            // A1/R1：CdnRewrite.settingsProvider 改由 AppBootstrap 启动时一次性注入，
            // 不再依赖 SettingsView.onAppear（首启门禁前 SettingsView 根本不存在）。
        }
        // A3/R3：副作用全部收敛到 Store.onPersistedEffects（落盘成功才执行），
        // 视图只负责把未落盘的防抖编辑及时 flush（切页/压后台不丢编辑）。
        .onDisappear {
            Task { await store.flushPendingEdits() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                Task { await store.flushPendingEdits() }
            }
        }
    }

    // MARK: 关于（R3 问题 4：NavigationLink 子页 AboutView；不再挂保存状态行）

    private var aboutLink: some View {
        NavigationLink {
            AboutView()
        } label: {
            HStack(spacing: 0) {
                AppText("关于", lvl: .bodyS, fontWeight: .bold)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundColor(theme.text2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: ComponentMetrics.cardCorner).fill(theme.bg1))
            .overlay(RoundedRectangle(cornerRadius: ComponentMetrics.cardCorner)
                .stroke(theme.line, lineWidth: ComponentMetrics.cardStroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings_about_link")
    }
}
