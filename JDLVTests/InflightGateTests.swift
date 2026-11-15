import XCTest
@testable import JDLV

// R5 P2：InflightGate（in-flight 去重门）单测 —— ImagePipeline.Inflight 竞态修复的
// 抽出件。覆盖 03_PHASE2 §5 四场景：
//  - 同 URL 并发 10 次 → body 只执行一次，全部拿到同一结果；
//  - 失败后不残留（条目移除，下次请求起新任务）；
//  - 取消后不泄漏（立即移除 + 等待方收 CancellationError）；
//  - 重复请求拿到同一结果。
// 全部确定性 barrier（await task.value / has(key) 轮询终态），不靠 sleep 碰运气。
final class InflightGateTests: XCTestCase {

    private actor CallCounter {
        var count = 0
        func bump() { count += 1 }
        var value: Int { count }
    }

    // MARK: 并发 10 次 → 单次执行 + 同结果

    func testConcurrentRequestsDeduplicateToSingleExecution() async throws {
        let gate = InflightGate<String, Int>()
        let counter = CallCounter()
        let tasks = (0..<10).map { _ in
            gate.entry("k") {
                await counter.bump()
                return 42
            }
        }
        let results = try await withThrowingTaskGroup(of: Int.self) { group -> [Int] in
            for t in tasks { group.addTask { try await t.value } }
            var out: [Int] = []
            for try await v in group { out.append(v) }
            return out
        }
        XCTAssertEqual(results.count, 10)
        XCTAssertEqual(Set(results), [42], "全部等待方拿到同一结果")
        let exec = await counter.value
        XCTAssertEqual(exec, 1, "body 只执行一次")
        let leaked = gate.has("k")
        XCTAssertFalse(leaked, "完成后条目确定性移除，无残留")
    }

    // MARK: 失败后不残留

    func testFailureDoesNotLeaveResidualEntry() async throws {
        let gate = InflightGate<String, Int>()
        let counter = CallCounter()
        let t1 = gate.entry("k") {
            await counter.bump()
            throw FetchFailure("boom")
        }
        do {
            _ = try await t1.value
            XCTFail("必须抛错")
        } catch let e as FetchFailure {
            XCTAssertEqual(e.description, "boom")
        }
        XCTAssertFalse(gate.has("k"), "失败任务退出即移除，无残留")

        // 失败后同键新请求 → 新任务（可成功）
        let t2 = gate.entry("k") { 7 }
        let v = try await t2.value
        XCTAssertEqual(v, 7)
        let exec = await counter.value
        XCTAssertEqual(exec, 1, "第二次成功 body 是新的（失败 counter 未再 bump）")
        XCTAssertFalse(gate.has("k"))
    }

    // MARK: 取消后不泄漏 + 等待方收取消错误

    func testCancelRemovesEntryAndPropagatesCancellation() async throws {
        let gate = InflightGate<String, Int>()
        let started = XCTestExpectation(description: "body started")
        let t = gate.entry("k") {
            started.fulfill()
            // 可取消等待：cancel 置位后立即退出（结果断言不依赖轮询时序）
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            throw CancellationError()
        }
        await fulfillment(of: [started], timeout: 2)
        gate.cancel("k")
        XCTAssertFalse(gate.has("k"), "cancel 立即移除条目")
        do {
            _ = try await t.value
            XCTFail("取消后必须抛 CancellationError")
        } catch is CancellationError {
            // 预期：取消传播
        }
        // 退出路径再次移除（身份比对失败）→ 无残留
        XCTAssertFalse(gate.has("k"))

        // 取消后同键新请求 → 新任务可正常完成
        let t2 = gate.entry("k") { 9 }
        let v = try await t2.value
        XCTAssertEqual(v, 9)
    }

    // MARK: 重复请求拿到同一结果

    func testRepeatRequestsGetConsistentResult() async throws {
        let gate = InflightGate<String, Int>()
        let first = try await gate.entry("k") { 123 }.value
        let second = try await gate.entry("k") { 123 }.value   // 新任务（前条目已移除）
        XCTAssertEqual(first, second)
        let third = try await gate.entry("k") { 123 }.value
        XCTAssertEqual(third, 123)
        XCTAssertFalse(gate.has("k"))
    }

    // MARK: R6 PHASE2：兴趣票语义 —— 一方离开绝不取消他方

    func testLeaveOneInterestKeepsTaskForRemainingWaiter() async throws {
        let gate = InflightGate<String, Int>()
        let started = XCTestExpectation(description: "body started")
        let a = UUID(), b = UUID()
        let ta = gate.entry("k", interest: a) {
            started.fulfill()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            throw CancellationError()
        }
        await fulfillment(of: [started], timeout: 2)
        let tb = gate.entry("k", interest: b) {
            throw CancellationError()
        }
        XCTAssertTrue(gate.has("k"))
        gate.leave("k", interest: a)   // A 离开：B 仍在 → 条目保留、任务不取消
        XCTAssertTrue(gate.has("k"), "仍有等待方时条目不得移除（R6：同 URL 多视图互不波及）")
        gate.leave("k", interest: b)   // 最后一人离开 → 取消并移除
        XCTAssertFalse(gate.has("k"), "兴趣清空后条目立即移除")
        do {
            _ = try await tb.value
            XCTFail("全部兴趣离开后共享任务必须被取消")
        } catch is CancellationError {
            // 预期：取消传播（ta/tb 同任务句柄）
        }
        _ = ta
    }

    func testLeaveUnknownInterestIsNoOp() async throws {
        let gate = InflightGate<String, Int>()
        let started = XCTestExpectation(description: "body started")
        let a = UUID()
        let t = gate.entry("k", interest: a) {
            started.fulfill()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            throw CancellationError()
        }
        await fulfillment(of: [started], timeout: 2)
        gate.leave("k", interest: UUID())   // 未登记的票 → no-op
        XCTAssertTrue(gate.has("k"), "未知票不得影响在飞条目")
        gate.leave("k", interest: a)
        XCTAssertFalse(gate.has("k"))
        _ = try? await t.value
    }

    func testSameInterestReentryIsIdempotent() async throws {
        let gate = InflightGate<String, Int>()
        let counter = CallCounter()
        let started = XCTestExpectation(description: "body started")
        final class Hold: @unchecked Sendable {
            private let lk = NSLock()
            private var open = false
            func isOpen() -> Bool { lk.lock(); defer { lk.unlock() }; return open }
            func openIt() { lk.lock(); open = true; lk.unlock() }
        }
        let hold = Hold()
        let a = UUID()
        let t1 = gate.entry("k", interest: a) {
            await counter.bump()
            started.fulfill()
            while !hold.isOpen() && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return 1
        }
        await fulfillment(of: [started], timeout: 2)
        let t2 = gate.entry("k", interest: a) { 2 }   // 同票同键在飞 → 复用
        hold.openIt()
        let v1 = try await t1.value
        let v2 = try await t2.value
        XCTAssertEqual(v1, 1)
        XCTAssertEqual(v2, 1, "同票重入复用同一任务结果")
        let exec = await counter.value
        XCTAssertEqual(exec, 1, "body 只执行一次")
        XCTAssertFalse(gate.has("k"))
    }
}

