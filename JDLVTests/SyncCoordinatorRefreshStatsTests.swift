import XCTest
import JDLVCore

// R6 SEG-02：refreshStats 空闲态回填/计数缓存失效 ——
// 插入行后 refreshStats 必须反映真实行数；1s TTL 缓存不得在「刚插入」后返回旧值。
final class SyncCoordinatorRefreshStatsTests: XCTestCase {

    private func makeTempIdx() throws -> (IdxDb, String) {
        let dir = NSTemporaryDirectory() + "seg02_\(UUID().uuidString.prefix(8))/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let idx = try IdxDb(directory: dir)
        return (idx, dir)
    }

    private func movieRow(_ id: String) -> Row {
        Row(["id": .string(id), "title": .string("t-\(id)")])
    }

    private func coordinator(idx: IdxDb) -> SyncCoordinator {
        SyncCoordinator(
            idx: idx,
            source: WarmDbSourceFactory(),
            settings: { WarmSettings(enabled: false, idxMode: true,
                                     limitJdb: 50_000, limitSht: 50_000,
                                     actorIndex: false, actorLinks: false, tagIndex: false) })
    }

    func testRefreshStatsReflectsInsertedRows() throws {
        let (idx, dir) = try makeTempIdx()
        defer {
            idx.close()
            try? FileManager.default.removeItem(atPath: dir)
        }
        let coord = coordinator(idx: idx)

        XCTAssertEqual(coord.state.movies, 0, "空库应为 0")

        idx.upsertMovies([movieRow("m1"), movieRow("m2"), movieRow("m3")])
        coord.refreshStats()
        XCTAssertEqual(coord.state.movies, 3, "refreshStats 后应反映真实行数")

        // 1s TTL 内再次插入再刷新：不得返回缓存旧值
        idx.upsertMovies([movieRow("m4")])
        coord.refreshStats()
        XCTAssertEqual(coord.state.movies, 4, "TTL 缓存未失效 → 旧值泄漏")
    }

    func testCountOfExactBypassesTTL() throws {
        let (idx, dir) = try makeTempIdx()
        defer {
            idx.close()
            try? FileManager.default.removeItem(atPath: dir)
        }

        XCTAssertEqual(try idx.countOf(table: "idx_movies"), 0)
        idx.upsertMovies([movieRow("m1")])
        XCTAssertEqual(try idx.countOfExact(table: "idx_movies"), 1, "countOfExact 必须绕过 TTL")
        // countOf 可能命中 TTL 缓存返回旧值；显式失效后必须为 1
        idx.invalidateCountCache()
        XCTAssertEqual(try idx.countOf(table: "idx_movies"), 1)
    }
}
