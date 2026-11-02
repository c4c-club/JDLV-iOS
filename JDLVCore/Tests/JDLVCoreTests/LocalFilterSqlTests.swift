import Foundation
import XCTest
@testable import JDLVCore

/// B6. LocalFilterSqlTest —— 离线筛选 DSL（24 用例）。
/// 核心原则：非法/不支持的条件一律 fail-closed（`WHERE 1=0` + empty=true），
/// 绝不静默丢弃条件后返回全量。
/// reason 为中文逐字断言；多条 reason 用全角"；"连接。
final class LocalFilterSqlTests: XCTestCase {

    /// 固定区间注入：验证 build 完全尊重注入闭包（结果只允许出现固定值）
    private static let fixedMonthRange: (String, String) -> (String, String)? = { _, _ in
        ("2000-01-01", "2000-02-01")
    }

    /// 统一入口：默认注入 DateRange.monthRange（与生产 `DateRange::monthRange` 一致）
    private func build(
        _ f: Filters,
        tagIds: [String] = [],
        singleTagIds: [String] = [],
        caps: LocalCaps = LocalCaps(),
        monthRange: (String, String) -> (String, String)? = DateRange.monthRange
    ) -> LocalQuery {
        LocalFilterSql.build(
            f,
            tagIds: tagIds,
            singleTagIds: singleTagIds,
            caps: caps,
            monthRange: monthRange)
    }

    private func placeholders(_ sql: String) -> Int {
        sql.filter { $0 == "?" }.count
    }

    // MARK: - 年月区间 / substr 月份

    /// yearAndMonthUsesHalfOpenRange：year+month → 半开区间 [2024-08-01, 2024-09-01)，占位符 3
    func testYearAndMonthUsesHalfOpenRange() {
        let q = build(Filters(year: "2024", month: "8"))
        XCTAssertFalse(q.empty)
        XCTAssertTrue(q.where.contains("year = ?"))
        XCTAssertTrue(q.where.contains("release_date >= ? AND release_date < ?"))
        XCTAssertEqual(q.params, ["2024", "2024-08-01", "2024-09-01"])
        XCTAssertEqual(placeholders(q.where), 3)
    }

    /// monthOnlyUsesSubstr：仅月份走 substr 分支，补零到两位
    func testMonthOnlyUsesSubstr() {
        let q = build(Filters(month: "8"))
        XCTAssertFalse(q.empty)
        XCTAssertTrue(q.where.contains("substr(release_date, 6, 2) = ?"))
        XCTAssertEqual(q.params, ["08"])
        XCTAssertEqual(placeholders(q.where), 1)
    }

    /// monthOnlyDecemberUsesSubstrAndPads：12 月同样走 substr 分支
    func testMonthOnlyDecemberUsesSubstrAndPads() {
        let q = build(Filters(month: "12"))
        XCTAssertFalse(q.empty)
        XCTAssertTrue(q.where.contains("substr(release_date, 6, 2) = ?"))
        XCTAssertEqual(q.params, ["12"])
        XCTAssertEqual(placeholders(q.where), 1)
    }

    /// monthOnlyJanuaryIsIndependentOfYear：仅 month=1 不得隐含年份区间
    func testMonthOnlyJanuaryIsIndependentOfYear() {
        let q = build(Filters(month: "1"))
        XCTAssertFalse(q.empty)
        XCTAssertEqual(q.params, ["01"])
        XCTAssertTrue(q.where.contains("substr(release_date, 6, 2) = ?"))
        XCTAssertFalse(q.where.contains("release_date >="), "仅月份不得生成日期区间")
        XCTAssertFalse(q.where.contains("release_date <"))
    }

    /// leapFebruaryRange：闰年 2 月按月首/次月首
    func testLeapFebruaryRange() {
        let q = build(Filters(year: "2024", month: "2"))
        XCTAssertFalse(q.empty)
        XCTAssertEqual(q.params, ["2024", "2024-02-01", "2024-03-01"])
    }

    /// decemberCrossesYear：12 月区间跨年
    func testDecemberCrossesYear() {
        let q = build(Filters(year: "2024", month: "12"))
        XCTAssertFalse(q.empty)
        XCTAssertEqual(q.params, ["2024", "2024-12-01", "2025-01-01"])
    }

    // MARK: - 非法输入 fail-closed

    /// invalidMonthFailsClosed：month=13 → WHERE 1=0，reason 逐字
    func testInvalidMonthFailsClosed() {
        let q = build(Filters(year: "2024", month: "13"))
        XCTAssertTrue(q.empty)
        XCTAssertEqual(q.where, " WHERE 1=0")
        XCTAssertTrue(q.params.isEmpty)
        XCTAssertEqual(q.reason, "年份/月份非法，无法生成日期区间")
        XCTAssertTrue(q.reason.contains("非法"))
        XCTAssertTrue(q.unsupported.isEmpty)
    }

    /// invalidYearFailsClosed：year="24"（非 4 位）→ WHERE 1=0
    func testInvalidYearFailsClosed() {
        let q = build(Filters(year: "24", month: "8"))
        XCTAssertTrue(q.empty)
        XCTAssertEqual(q.where, " WHERE 1=0")
        XCTAssertTrue(q.params.isEmpty)
        XCTAssertEqual(q.reason, "年份/月份非法，无法生成日期区间")
    }

    /// monthOnlyInvalidFailsClosed：仅 month="0" → reason 逐字"月份非法"
    func testMonthOnlyInvalidFailsClosed() {
        let q = build(Filters(month: "0"))
        XCTAssertTrue(q.empty)
        XCTAssertEqual(q.where, " WHERE 1=0")
        XCTAssertTrue(q.params.isEmpty)
        XCTAssertEqual(q.reason, "月份非法")
    }

    // MARK: - 字头 LIKE 转义

    /// letterEscapesLikeWildcards：小写化 + %_\ 转义，前缀通配符只出现在参数里
    func testLetterEscapesLikeWildcards() {
        let q = build(Filters(letter: "A_B%"), monthRange: Self.fixedMonthRange)
        XCTAssertFalse(q.empty)
        XCTAssertTrue(q.where.contains("number LIKE ? ESCAPE '\\'"))
        XCTAssertEqual(q.params, ["a\\_b\\%%"])
        XCTAssertEqual(placeholders(q.where), 1)
    }

    /// sqlDoesNotContainUnescapedPercentOutsideParams：letter="%" → where 不含裸 %
    func testSqlDoesNotContainUnescapedPercentOutsideParams() {
        let q = build(Filters(letter: "%"), monthRange: Self.fixedMonthRange)
        XCTAssertFalse(q.empty)
        XCTAssertFalse(q.where.contains("%"), "通配符只允许出现在绑定参数内")
        XCTAssertTrue(q.where.contains("ESCAPE '\\'"))
        XCTAssertEqual(q.params, ["\\%%"])
    }

    // MARK: - 标签子查询

    /// multipleTagsProduceMultipleSubqueries：每 tag 一个子查询，参数保序
    func testMultipleTagsProduceMultipleSubqueries() {
        var f = Filters()
        f.tags = "巨乳,人妻"
        let q = build(f, tagIds: ["101", "202"], monthRange: Self.fixedMonthRange)
        XCTAssertFalse(q.empty)
        XCTAssertEqual(q.params, ["101", "202"])
        XCTAssertEqual(
            q.where.components(separatedBy: "idx_movie_tags").count - 1, 2,
            "每 tag 一个子查询：idx_movie_tags 应出现 2 次")
        XCTAssertEqual(q.where.components(separatedBy: "tag_id = ?").count - 1, 2)
    }

    /// tagsWithoutMappedIdsFailsClosed：标签名无法映射 → fail-closed，reason 逐字
    func testTagsWithoutMappedIdsFailsClosed() {
        var f = Filters()
        f.tags = "巨乳"
        let q = build(f, tagIds: [])
        XCTAssertTrue(q.empty)
        XCTAssertEqual(q.where, " WHERE 1=0")
        XCTAssertTrue(q.params.isEmpty)
        XCTAssertEqual(q.reason, "标签名无法映射 (需先联网加载标签索引)")
        XCTAssertTrue(q.unsupported.isEmpty)
    }

    // MARK: - 单体筛选

    /// singleHitUsesTagIds：单体 tag ids → tag_id IN (?,?)
    func testSingleHitUsesTagIds() {
        var f = Filters()
        f.single = true
        let q = build(f, singleTagIds: ["11", "22"], monthRange: Self.fixedMonthRange)
        XCTAssertFalse(q.empty)
        XCTAssertTrue(q.where.contains("tag_id IN (?,?)"))
        XCTAssertEqual(q.params, ["11", "22"])
    }

    /// singleWithoutTagIdsFailsClosed：无 ids → fail-closed，reason 逐字
    func testSingleWithoutTagIdsFailsClosed() {
        var f = Filters()
        f.single = true
        let q = build(f, singleTagIds: [])
        XCTAssertTrue(q.empty)
        XCTAssertEqual(q.where, " WHERE 1=0")
        XCTAssertTrue(q.params.isEmpty)
        XCTAssertEqual(q.reason, "标签索引未就绪，无法执行单体筛选")
        XCTAssertTrue(q.reason.contains("单体"))
    }

    /// singleSubqueryUsesAllResolvedIds：3 个 ids 全部进 IN (?,?,?)
    func testSingleSubqueryUsesAllResolvedIds() {
        var f = Filters()
        f.single = true
        let q = build(f, singleTagIds: ["a", "b", "c"], monthRange: Self.fixedMonthRange)
        XCTAssertFalse(q.empty)
        XCTAssertTrue(q.where.contains("tag_id IN (?,?,?)"))
        XCTAssertEqual(q.params, ["a", "b", "c"])
        XCTAssertEqual(q.params.count, 3)
    }

    // MARK: - 能力缺失 fail-closed

    /// cnsubFailsClosedWhenCapabilityMissing：cnsub 能力缺 → unsupported="无码"
    func testCnsubFailsClosedWhenCapabilityMissing() {
        var f = Filters()
        f.cnsub = true
        let q = build(f)  // LocalCaps 默认 cnsub=false
        XCTAssertTrue(q.empty)
        XCTAssertEqual(q.where, " WHERE 1=0")
        XCTAssertTrue(q.params.isEmpty)
        XCTAssertEqual(q.unsupported, ["无码"])
        XCTAssertEqual(q.reason, "无码：离线不支持该条件，请联网或清除该条件")
    }

    /// canPlayFailsClosedWhenCapabilityMissing：canPlay 能力缺 → unsupported="可播放"
    func testCanPlayFailsClosedWhenCapabilityMissing() {
        var f = Filters()
        f.canPlay = true
        let q = build(f)  // LocalCaps 默认 canPlay=false
        XCTAssertTrue(q.empty)
        XCTAssertEqual(q.where, " WHERE 1=0")
        XCTAssertTrue(q.params.isEmpty)
        XCTAssertEqual(q.unsupported, ["可播放"])
        XCTAssertEqual(q.reason, "可播放：离线不支持该条件，请联网或清除该条件")
    }

    /// yearCapabilityOffFailsClosed：year 能力关 → unsupported="年份"，reason 逐字
    func testYearCapabilityOffFailsClosed() {
        let q = build(Filters(year: "2024"), caps: LocalCaps(year: false))
        XCTAssertTrue(q.empty)
        XCTAssertEqual(q.where, " WHERE 1=0")
        XCTAssertTrue(q.params.isEmpty)
        XCTAssertEqual(q.unsupported, ["年份"])
        XCTAssertEqual(q.reason, "年份：离线不支持该条件，请联网或清除该条件")
    }

    /// allCapsFalseFailsClosed：全部能力关闭 + 12 项条件全开 → unsupported >= 10，
    /// 多条 reason 用全角"；"连接
    func testAllCapsFalseFailsClosed() {
        var f = Filters()
        f.year = "2024"; f.month = "8"; f.maker = "m"; f.letter = "a"
        f.tags = "t"; f.magnet = true; f.cnsub = true; f.canPlay = true
        f.single = true; f.seriesId = "s"; f.directorId = "d"; f.publisherId = "p"
        let caps = LocalCaps(
            year: false, month: false, letter: false, maker: false, series: false,
            director: false, publisher: false, tags: false, magnet: false,
            single: false, cnsub: false, canPlay: false)
        let q = build(f, tagIds: ["1"], singleTagIds: ["11"], caps: caps)
        XCTAssertTrue(q.empty)
        XCTAssertEqual(q.where, " WHERE 1=0")
        XCTAssertTrue(q.params.isEmpty)
        XCTAssertGreaterThanOrEqual(q.unsupported.count, 10)
        XCTAssertTrue(q.reason.contains("；"), "多条 reason 应用全角分号连接：\(q.reason)")
        XCTAssertEqual(
            q.reason.components(separatedBy: "；").count, q.unsupported.count,
            "reason 条数应与 unsupported 一致")
    }

    // MARK: - 空筛选 / 磁力 / 组合

    /// emptyFiltersProduceEmptyWhere：无筛选 → where="" 且非 empty
    func testEmptyFiltersProduceEmptyWhere() {
        let q = build(Filters())
        XCTAssertFalse(q.empty)
        XCTAssertEqual(q.where, "")
        XCTAssertTrue(q.params.isEmpty)
        XCTAssertTrue(q.unsupported.isEmpty)
        XCTAssertEqual(q.reason, "")
    }

    /// magnetOnlyDoesNotNeedParameters：magnet=true → 布尔条件无需参数
    func testMagnetOnlyDoesNotNeedParameters() {
        var f = Filters()
        f.magnet = true
        let q = build(f, monthRange: Self.fixedMonthRange)
        XCTAssertFalse(q.empty)
        XCTAssertTrue(q.where.contains("magnets > 0"))
        XCTAssertEqual(q.where, " WHERE magnets > 0")
        XCTAssertTrue(q.params.isEmpty)
    }

    /// combinedConditionsKeepOrderAndParamCount：9 条件组合 → params 顺序固定、
    /// params 数 == 占位符数
    func testCombinedConditionsKeepOrderAndParamCount() {
        let f = Filters(
            year: "2024", month: "8", maker: "m1", letter: "ABC", tags: "标签A",
            magnet: true, seriesId: "s1", directorId: "d1", publisherId: "p1")
        let q = build(f, tagIds: ["9"])
        XCTAssertFalse(q.empty)
        XCTAssertTrue(q.unsupported.isEmpty)
        XCTAssertEqual(
            q.params,
            ["2024", "2024-08-01", "2024-09-01", "abc%", "m1", "s1", "d1", "p1", "9"])
        XCTAssertEqual(placeholders(q.where), q.params.count)
        XCTAssertEqual(
            q.where,
            " WHERE year = ?"
                + " AND release_date >= ? AND release_date < ?"
                + " AND number LIKE ? ESCAPE '\\'"
                + " AND maker_id = ? AND series_id = ? AND director_id = ? AND publisher_id = ?"
                + " AND id IN (SELECT movie_id FROM idx_movie_tags WHERE tag_id = ?)"
                + " AND magnets > 0")
    }

    /// paramsAndPlaceholdersAlwaysMatch：5 组典型案例，非 empty 时 params.size 恒等于占位符数
    func testParamsAndPlaceholdersAlwaysMatch() {
        var f1 = Filters(); f1.year = "2023"; f1.month = "2"
        var f2 = Filters(); f2.letter = "D_E%"
        var f3 = Filters(); f3.tags = "巨乳,人妻"
        var f4 = Filters(); f4.maker = "m"; f4.seriesId = "s"; f4.directorId = "d"
        var f5 = Filters(); f5.single = true

        let queries = [
            build(f1),
            build(f2, monthRange: Self.fixedMonthRange),
            build(f3, tagIds: ["1", "2"], monthRange: Self.fixedMonthRange),
            build(f4, monthRange: Self.fixedMonthRange),
            build(f5, singleTagIds: ["a", "b", "c"], monthRange: Self.fixedMonthRange),
        ]
        for q in queries {
            XCTAssertFalse(q.empty)
            XCTAssertEqual(q.params.count, placeholders(q.where))
        }
    }
}
