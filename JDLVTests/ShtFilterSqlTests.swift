import XCTest
import JDLVCore
@testable import JDLV

// R3 问题 9：98t 主版筛选 SQL 口径单测（13 §6.1 ShtFilterSqlTests）。
// 语义用例（正常 board / 空串 / NULL / 不命中 / mains=sum(subs)）在 CI core-mysql
// QIntegrationTests.test_Q_shtBrowse_filters / test_Q_shtCategories_segments 用
// fixture（1003 board=NULL、1007 board=''）覆盖；本文件做 SQL 准入（SqlPolicy）与
// 拼接形态断言（Windows 无 swift 运行时，CI 验证）。
final class ShtFilterSqlTests: XCTestCase {

    private func check(_ which: String, _ sql: String) -> String? {
        SqlPolicy.check(which, sql)
    }

    /// 新主版过滤片段（与 ShtSearch.list/count、Q.shtExport 一致）
    private var mainFilter: String {
        "COALESCE(NULLIF(TRIM(t.board), ''), t.cat_name) = 'tc'"
    }

    func testListPageSqlWithCoalescePassesPolicy() {
        let sql = "SELECT tid, title, post_date FROM sht_threads t WHERE \(mainFilter) " +
            "ORDER BY t.post_date DESC, t.tid DESC LIMIT ? OFFSET ?"
        XCTAssertNil(check("sht.list.page", sql),
                     "COALESCE 主版过滤必须通过 sht.list.page 准入")
    }

    func testListDerivedSqlWithCoalescePassesPolicy() {
        let sql = "SELECT tid, title FROM (SELECT tid FROM sht_threads ORDER BY tid DESC LIMIT 20000) k " +
            "JOIN sht_threads t ON t.tid = k.tid WHERE \(mainFilter) " +
            "ORDER BY t.post_date DESC, t.tid DESC LIMIT ? OFFSET ?"
        XCTAssertNil(check("sht.list.derived", sql))
    }

    func testCountSqlWithCoalescePassesPolicy() {
        let sql = "SELECT COUNT(*) FROM sht_threads t WHERE \(mainFilter)"
        XCTAssertNil(check("sht.count.page", sql))
    }

    func testCategoriesSubsSqlWithCoalescePassesPolicy() {
        let sql = "SELECT COALESCE(NULLIF(TRIM(board), ''), cat_name) main, board_name name, " +
            "COUNT(*) c FROM (SELECT board, board_name, cat_name FROM sht_threads " +
            "ORDER BY tid DESC LIMIT 80000) k WHERE board_name IS NOT NULL " +
            "GROUP BY main, board_name"
        XCTAssertNil(check("sht.cat.subs", sql),
                     "sht.cat.subs 模板必须与新 COALESCE SELECT 列同步")
    }

    func testExportSqlWithCoalescePassesPolicy() {
        let sql = "SELECT t.tid, t.title, t.post_date, t.board_name FROM sht_threads t " +
            "WHERE \(mainFilter) ORDER BY t.post_date DESC LIMIT ? OFFSET ?"
        XCTAssertNil(check("sht.export.page", sql))
    }

    func testOldOrFilterStillPassesPolicy() {
        // 旧 OR 形态也要仍被 where .* 吞掉（回滚安全）
        let sql = "SELECT tid, title FROM sht_threads t WHERE (t.board = 'tc' OR " +
            "(t.board IS NULL AND t.cat_name = 'tc')) ORDER BY t.post_date DESC, t.tid DESC LIMIT ? OFFSET ?"
        XCTAssertNil(check("sht.list.page", sql))
    }
}
