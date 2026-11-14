import Foundation
import JDLVCore

/// R4 P6（§17.5.1）：LocalStore（SQLite）串行后台 actor —— 收藏/已读的全部磁盘 I/O 离
/// MainActor（主线程禁区硬规则 14）。LocalStore 的打开/DDL/读写都发生在 actor 执行器上。
/// 注入失败注入（KeychainStore 同款思路不可用于 SQLite）—— 测试用内存 Fake 走 FavsStore 协议。
actor LocalStoreActor {
    private let store: LocalStore

    init(store: LocalStore) { self.store = store }

    func favList(kind: String) throws -> [Row] {
        try store.favList(kind: kind)
    }

    /// toggle 语义：已收藏 → 取消（false）；未收藏 → 收藏（true）
    func favToggle(kind: String, id: String, title: String) throws -> Bool {
        try store.favToggle(kind: kind, itemId: id, title: title)
    }

    func historyIs(kind: String, id: String) throws -> Bool {
        try store.historyIs(kind: kind, itemId: id)
    }

    func favIs(kind: String, id: String) throws -> Bool {
        try store.favIs(kind: kind, itemId: id)
    }

    func historyMark(kind: String, id: String, title: String) throws {
        try store.historyMark(kind: kind, itemId: id, title: title)
    }

    /// 批量已读集合（A-1：列表页批量 IN 查）
    func historySet(kind: String, ids: [String]) throws -> Set<String> {
        try store.historySet(kind: kind, ids: ids)
    }

    /// 批量收藏集合（A-1）
    func favSet(kind: String, ids: [String]) throws -> Set<String> {
        try store.favSet(kind: kind, ids: ids)
    }
}
