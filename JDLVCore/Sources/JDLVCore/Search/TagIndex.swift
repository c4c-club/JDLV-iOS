import Foundation

/// 标签双向索引（纯逻辑）。
/// 合并优先级：远程 taxonomy > assets；同名不同 id 以远程为准；
/// id→name 优先远程 name，缺失回退 assets。查不到返回 nil 由 UI 显示 #id。
public struct TagIndex: Equatable {
    private let nameToId: [String: String]
    private let idToName: [String: String]

    public init(nameToId: [String: String], idToName: [String: String]) {
        self.nameToId = nameToId
        self.idToName = idToName
    }

    public func idOf(_ name: String?) -> String? {
        let k = (name ?? "").trimmingCharacters(in: .whitespaces)
        if k.isEmpty { return nil }
        return nameToId[k]
    }

    public func nameOf(_ id: String?) -> String? {
        let k = (id ?? "").trimmingCharacters(in: .whitespaces)
        if k.isEmpty { return nil }
        return idToName[k]
    }

    public func isEmpty() -> Bool {
        nameToId.isEmpty && idToName.isEmpty
    }

    /// 远程优先合并：远程有名字→id 时覆盖 assets；id→name 远程缺失回退 assets。
    public func mergeWith(_ remote: TagIndex?) -> TagIndex {
        guard let remote, !remote.isEmpty() else { return self }
        var n = nameToId
        for (k, v) in remote.nameToId { n[k] = v }   // 远程同名覆盖
        var d = idToName
        for (k, v) in remote.idToName { d[k] = v }   // 远程 id→name 覆盖
        return TagIndex(nameToId: n, idToName: d)
    }

    public static let EMPTY = TagIndex(nameToId: [:], idToName: [:])

    /// pairs = (id, name)；同 id 首个真实名保留（占位名 name==id 不锁死 id→name）。
    public static func of(_ pairs: [(String, String)]) -> TagIndex {
        if pairs.isEmpty { return EMPTY }
        var n: [String: String] = [:]
        var d: [String: String] = [:]
        for (id, name) in pairs {
            if id.isEmpty || name.isEmpty { continue }
            n[name] = id
            // assets 存在 id=10/8 的占位名（name==id），占位名不能锁死 id→name
            let prev = d[id]
            let prevBlank = prev?.trimmingCharacters(in: .whitespaces).isEmpty != false
            if prev == nil || prev == id || prevBlank {
                d[id] = name
            }
        }
        return TagIndex(nameToId: n, idToName: d)
    }

    public static func merge(_ assets: TagIndex?, _ remote: TagIndex?) -> TagIndex {
        (assets ?? EMPTY).mergeWith(remote)
    }
}
