import Foundation

/// 浏览/反查共用的 12 字段筛选（对齐 Android Q.Filters）。
/// 序列化字段名固定（反查 payload 三端兼容，LookupCodec）。
public struct Filters: Equatable, Codable, Hashable {
    public var year: String
    public var month: String
    public var maker: String
    public var letter: String
    public var tags: String
    public var magnet: Bool
    public var cnsub: Bool
    public var canPlay: Bool
    public var single: Bool
    public var seriesId: String
    public var directorId: String
    public var publisherId: String

    public init(
        year: String = "", month: String = "", maker: String = "", letter: String = "",
        tags: String = "", magnet: Bool = false, cnsub: Bool = false, canPlay: Bool = false,
        single: Bool = false, seriesId: String = "", directorId: String = "",
        publisherId: String = ""
    ) {
        self.year = year
        self.month = month
        self.maker = maker
        self.letter = letter
        self.tags = tags
        self.magnet = magnet
        self.cnsub = cnsub
        self.canPlay = canPlay
        self.single = single
        self.seriesId = seriesId
        self.directorId = directorId
        self.publisherId = publisherId
    }

    public var isBlank: Bool { self == Filters() }

    /// tags CSV 增删（BrowseVm.toggleTag 语义）
    public mutating func toggleTag(_ name: String) {
        var list = tags.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let idx = list.firstIndex(of: name) {
            list.remove(at: idx)
        } else {
            list.append(name)
        }
        tags = list.joined(separator: ",")
    }
}
