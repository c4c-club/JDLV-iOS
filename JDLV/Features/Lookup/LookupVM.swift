import Foundation
import JDLVCore

//
//  LookupVM.swift —— 反查结果页 VM（10 §6 LookupScreen/LookupCodec 移植）。
//
//  - payload = LookupCodec.encode(LookupSpec) 的 Base64 URL-safe 无填充串（三端互认）；
//    decode 失败（runCatching→nil）→ spec == nil → 页面兜底空态「反查参数无效」。
//  - 独立 VM：每层 lookup 路由各自持有 BrowseVm 实例（iOS 对位：push 自持
//    @StateObject/ObservableObject），筛选状态互不污染、浏览 tab 状态不受影响。
//  - embedded 模式 skipBind：不执行 BrowseVM.bind（浏览 tab 的 bind/loadFilters 语义
//    不适用），由本 VM 首次 applyFilters(spec.filters, spec.sort)（恒一次）。
//  - label 默认「反查」（spec.label 空/缺失时兜底）。
//

@MainActor
final class LookupVM: ObservableObject {

    /// 解码结果（nil = 参数无效，页面兜底空态）
    let spec: LookupSpec?
    /// 反查页内嵌浏览的独立 VM 实例（每层 lookup 各自一份）
    let browseVM: BrowseVM

    private var applied = false

    /// browseVM 可注入（测试）；默认自建（生产走同一 BrowseDataSource 协议）
    init(payload: String, browseVM: BrowseVM? = nil) {
        self.spec = LookupCodec.decode(payload)
        self.browseVM = browseVM ?? BrowseVM()
    }

    /// 顶栏 label（默认「反查」）
    var label: String {
        let l = spec?.label ?? ""
        return l.isEmpty ? AppCopy.lookupDefaultLabel : l
    }

    /// 首次进入执行 applyFilters（sort 非空 → 反查带排序恒倒序，BrowseVM.applyFilters 内保证）
    func applyOnce() async {
        guard !applied, let spec else { return }
        applied = true
        await browseVM.applyFilters(spec.filters, sortOverride: spec.sort)
    }
}
