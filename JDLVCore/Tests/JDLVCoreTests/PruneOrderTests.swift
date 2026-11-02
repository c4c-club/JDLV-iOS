import XCTest
@testable import JDLVCore

// 对应 Android PruneOrderTest.kt（12 用例）：索引裁剪 SQL 生成器。
final class PruneOrderTests: XCTestCase {
    func test_movieEvictOrderIsDataScanOrder() {
        XCTAssertEqual(PruneSql.MOVIE_EVICT_ORDER, "release_date ASC, id ASC")
    }

    func test_threadEvictOrderIsTidAsc() {
        XCTAssertEqual(PruneSql.THREAD_EVICT_ORDER, "tid ASC")
    }

    func test_movieInsertUsesEvictOrder() {
        let stmts = PruneSql.movieStatements(123)
        let insert = stmts.first { $0.0.hasPrefix("INSERT INTO _del_ids") }
        XCTAssertNotNil(insert)
        XCTAssertTrue(insert!.0.hasSuffix("ORDER BY release_date ASC, id ASC LIMIT ?"))
        XCTAssertEqual(insert!.1, ["123"])
    }

    func test_threadInsertUsesTidOrder() {
        let stmts = PruneSql.threadStatements(456)
        let insert = stmts.first { $0.0.hasPrefix("INSERT INTO _del_ids") }
        XCTAssertNotNil(insert)
        XCTAssertTrue(insert!.0.hasSuffix("ORDER BY tid ASC LIMIT ?"))
        XCTAssertEqual(insert!.1, ["456"])
    }

    func test_movieStatementsCleanBothRelationTables() {
        let joined = PruneSql.movieStatements(1).map { $0.0 }.joined(separator: "\n")
        XCTAssertTrue(joined.contains("DELETE FROM idx_movie_tags WHERE movie_id IN (SELECT id FROM _del_ids)"))
        XCTAssertTrue(joined.contains("DELETE FROM idx_movie_actors WHERE movie_id IN (SELECT id FROM _del_ids)"))
    }

    func test_movieStatementsDeleteMoviesByTempIds() {
        let joined = PruneSql.movieStatements(1).map { $0.0 }.joined(separator: "\n")
        XCTAssertTrue(joined.contains("DELETE FROM idx_movies WHERE id IN (SELECT id FROM _del_ids)"))
    }

    func test_updatedAtNeverUsedAsEvictionKey() {
        let all = (PruneSql.movieStatements(1).map { $0.0 }
            + PruneSql.threadStatements(1).map { $0.0 }
            + [PruneSql.MOVIE_BOUNDARY, PruneSql.THREAD_BOUNDARY])
            .joined(separator: "\n")
        XCTAssertFalse(all.contains("updated_at"))
    }

    func test_statementsAreOrderedDropCreateInsertDeleteDrop() {
        let m = PruneSql.movieStatements(1).map { $0.0 }
        XCTAssertTrue(m.first!.hasPrefix("DROP TABLE IF EXISTS temp._del_ids"))
        XCTAssertTrue(m[1].hasPrefix("CREATE TEMP TABLE"))
        XCTAssertTrue(m.last!.hasPrefix("DROP TABLE IF EXISTS temp._del_ids"))
        let t = PruneSql.threadStatements(1).map { $0.0 }
        XCTAssertTrue(t.first!.hasPrefix("DROP TABLE IF EXISTS temp._del_ids"))
        XCTAssertTrue(t[1].hasPrefix("CREATE TEMP TABLE"))
        XCTAssertTrue(t.last!.hasPrefix("DROP TABLE IF EXISTS temp._del_ids"))
    }

    func test_boundaryQueriesUseEvictOrder() {
        XCTAssertTrue(PruneSql.MOVIE_BOUNDARY.contains("ORDER BY release_date ASC, id ASC LIMIT 1 OFFSET ?"))
        XCTAssertTrue(PruneSql.THREAD_BOUNDARY.contains("ORDER BY tid ASC LIMIT 1 OFFSET ?"))
    }

    func test_pruneOutcomeCarriesBoundary() {
        let o = PruneOutcome.success(deleted: 123, boundaryDate: "2025-07-24", boundaryId: "abc")
        XCTAssertEqual(o.boundaryDate, "2025-07-24")
        XCTAssertEqual(o.boundaryId, "abc")
        if case .success(let deleted, _, _) = o {
            XCTAssertEqual(deleted, 123)
        } else {
            XCTFail("expected success")
        }
    }

    func test_pruneFailedCarriesCause() {
        if case .failed(let cause) = PruneOutcome.failed("SQLiteFullException: disk full") {
            XCTAssertTrue(cause.contains("disk full"))
        } else {
            XCTFail("expected failed")
        }
    }

    func test_noopDoesNotClaimDeleted() {
        let o = PruneOutcome.noop(boundaryDate: "2026-01-01", boundaryId: "x")
        XCTAssertEqual(o.boundaryDate, "2026-01-01")
        XCTAssertEqual(o.boundaryId, "x")
        if case .noop = o {
            // Noop 不携带 deleted（不虚报删除数）
        } else {
            XCTFail("expected noop")
        }
    }
}
