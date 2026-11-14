import XCTest
import JDLVCore
@testable import JDLV

// R4 P6 门禁（任务 06 §17.5.6）：LocalStoreActor 串行后台执行 ——
// 并发 50 次 favToggle 不崩溃、计数一致；批量 historySet/favSet 正常。
final class LocalStoreActorTests: XCTestCase {

    private func makeActor() throws -> (LocalStoreActor, String) {
        let dir = NSTemporaryDirectory() + "jdlv_actor_\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = try LocalStore(directory: dir)
        return (LocalStoreActor(store: store), dir)
    }

    func testConcurrentFavToggle50DoesNotCrashAndCountIsConsistent() async throws {
        let (actorStore, dir) = try makeActor()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let results = await withTaskGroup(of: Bool.self) { group -> [Bool] in
            for i in 0..<50 {
                group.addTask {
                    (try? await actorStore.favToggle(kind: "movie", id: "m\(i)", title: "t\(i)")) ?? false
                }
            }
            var out: [Bool] = []
            for await r in group { out.append(r) }
            return out
        }
        XCTAssertEqual(results.filter { $0 }.count, 50, "50 次并发 toggle 全部成功（无崩溃/无丢失）")

        let list = try await actorStore.favList(kind: "movie")
        XCTAssertEqual(list.count, 50, "并发写入后行数一致（actor 串行化无竞态损坏）")
    }

    func testHistoryAndFavBatchQueries() async throws {
        let (actorStore, dir) = try makeActor()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try await actorStore.historyMark(kind: "movie", id: "a", title: "A")
        try await actorStore.historyMark(kind: "movie", id: "b", title: "B")
        _ = try await actorStore.favToggle(kind: "movie", id: "b", title: "B")

        let hist = try await actorStore.historySet(kind: "movie", ids: ["a", "b", "c"])
        XCTAssertEqual(hist, ["a", "b"])
        let favs = try await actorStore.favSet(kind: "movie", ids: ["a", "b", "c"])
        XCTAssertEqual(favs, ["b"])
        let hIs = try await actorStore.historyIs(kind: "movie", id: "a")
        XCTAssertTrue(hIs)
        let fIs = try await actorStore.favIs(kind: "movie", id: "b")
        XCTAssertTrue(fIs)
    }
}
