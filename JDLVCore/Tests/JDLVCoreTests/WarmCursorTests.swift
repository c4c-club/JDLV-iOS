//
//  WarmCursorTests.swift
//  JDLVCoreTests
//
//  对应 Android 套件: app/src/test/java/com/jdlv/mobile/WarmCursorTest.kt（规格文档 B16）
//  用例数: 12（方法名 = test_ + Android @Test 原名，一一对应）
//  被测: JDLVCore.WarmCursor.advance/nextWhenEmpty/phaseOf/phaseStr × MovieCursor(phase, date, id)
//        相位 SAME/TAIL/NULL/DONE；NULL 相位 date 恒 "__NULL__"（NULL_DATE 哨兵）
//        HEAD 态从不持久化读回（phaseOf("head") 读回即 TAIL 兜底）
//
//  Linux 兼容: 纯同步断言，无 XCTestExpectation / NSPredicate。
//

import XCTest
@testable import JDLVCore

final class WarmCursorTests: XCTestCase {

    // MARK: - B16. WarmCursorTest（12 用例）

    /// SAME 相位同日期批次 → 相位/日期不变，仅 id 前进 ("abc"→"bcd")
    func test_sameDayBatch_advancesIdOnly() {
        let cur = MovieCursor(phase: .same, date: "2024-06-21", id: "abc")
        let next = WarmCursor.advance(cur, lastDate: "2024-06-21", lastId: "bcd")
        XCTAssertEqual(next, MovieCursor(phase: .same, date: "2024-06-21", id: "bcd"))
    }

    /// NULL 相位批次（批末行 lastDate=""）→ 保持 NULL/"__NULL__"，仅 id 前进
    /// （NULL 相位 advance 只推进 id，date 不被批末行覆盖回 ""）
    func test_nullPhaseBatch_advancesIdOnly() {
        let cur = MovieCursor(phase: .null, date: WarmCursor.NULL_DATE, id: "abc")
        let next = WarmCursor.advance(cur, lastDate: "", lastId: "bcd")
        XCTAssertEqual(next, MovieCursor(phase: .null, date: WarmCursor.NULL_DATE, id: "bcd"))
    }

    /// TAIL(2024-06-21) 遇到更早日期 06-20 → 相位 SAME + date=06-20 + 新 id
    func test_tailBatch_fallsToSameDayOfNewDate() {
        let cur = MovieCursor(phase: .tail, date: "2024-06-21", id: "t1")
        let next = WarmCursor.advance(cur, lastDate: "2024-06-20", lastId: "x2")
        XCTAssertEqual(next, MovieCursor(phase: .same, date: "2024-06-20", id: "x2"))
    }

    /// SAME 空批次 → nextWhenEmpty → TAIL（同日扫完，date/id 保留）
    func test_emptyBatch_sameToTail() {
        let cur = MovieCursor(phase: .same, date: "2024-06-21", id: "abc")
        let next = WarmCursor.nextWhenEmpty(cur)
        XCTAssertEqual(next, MovieCursor(phase: .tail, date: "2024-06-21", id: "abc"))
    }

    /// TAIL 空批次 → NULL（date="__NULL__"，id=""，游标重置）
    func test_emptyBatch_tailToNullResetsCursor() {
        let cur = MovieCursor(phase: .tail, date: "2024-06-21", id: "abc")
        let next = WarmCursor.nextWhenEmpty(cur)
        XCTAssertEqual(next, MovieCursor(phase: .null, date: WarmCursor.NULL_DATE, id: ""))
    }

    /// NULL 空批次 → nextWhenEmpty 返回 nil（预热状态机结束）
    func test_emptyBatch_nullMeansDone() {
        let cur = MovieCursor(phase: .null, date: WarmCursor.NULL_DATE, id: "")
        XCTAssertNil(WarmCursor.nextWhenEmpty(cur))
    }

    /// HEAD 相位空批次 → 回落 TAIL（防御非法持久态；date/id 保留）
    func test_emptyBatch_headFallsBackToTail() {
        let cur = MovieCursor(phase: .head, date: "2024-06-21", id: "h1")
        let next = WarmCursor.nextWhenEmpty(cur)
        XCTAssertEqual(next, MovieCursor(phase: .tail, date: "2024-06-21", id: "h1"))
    }

    /// 全循环 SAME→advance→SAME→空→TAIL→新日期→SAME→空→TAIL→空→NULL→空→nil
    func test_fullCycle_sameTailNullDone() {
        var cur = MovieCursor(phase: .same, date: "2024-06-21", id: "m1")

        // SAME → advance（同日批）→ SAME
        cur = WarmCursor.advance(cur, lastDate: "2024-06-21", lastId: "m2")
        XCTAssertEqual(cur, MovieCursor(phase: .same, date: "2024-06-21", id: "m2"))

        // SAME 空批 → TAIL（date/id 保留）
        guard let t1 = WarmCursor.nextWhenEmpty(cur) else {
            return XCTFail("SAME 空批应转入 TAIL，而非结束")
        }
        cur = t1
        XCTAssertEqual(cur, MovieCursor(phase: .tail, date: "2024-06-21", id: "m2"))

        // TAIL → 新日期批 → SAME
        cur = WarmCursor.advance(cur, lastDate: "2024-06-22", lastId: "n1")
        XCTAssertEqual(cur, MovieCursor(phase: .same, date: "2024-06-22", id: "n1"))

        // SAME 空批 → TAIL
        guard let t2 = WarmCursor.nextWhenEmpty(cur) else {
            return XCTFail("SAME 空批应转入 TAIL，而非结束")
        }
        cur = t2
        XCTAssertEqual(cur, MovieCursor(phase: .tail, date: "2024-06-22", id: "n1"))

        // TAIL 空批 → NULL（游标重置）
        guard let n = WarmCursor.nextWhenEmpty(cur) else {
            return XCTFail("TAIL 空批应转入 NULL，而非结束")
        }
        cur = n
        XCTAssertEqual(cur, MovieCursor(phase: .null, date: WarmCursor.NULL_DATE, id: ""))

        // NULL 空批 → nil（结束）
        XCTAssertNil(WarmCursor.nextWhenEmpty(cur))
    }

    /// TAIL 落新日期回 SAME，同日继续推进 id（x2→x3，date 保持）
    func test_tailLandingOnNewDate_thenSameAgain() {
        let tail = MovieCursor(phase: .tail, date: "2024-06-22", id: "x1")
        let same = WarmCursor.advance(tail, lastDate: "2024-06-22", lastId: "x2")
        XCTAssertEqual(same, MovieCursor(phase: .same, date: "2024-06-22", id: "x2"))
        let again = WarmCursor.advance(same, lastDate: "2024-06-22", lastId: "x3")
        XCTAssertEqual(again, MovieCursor(phase: .same, date: "2024-06-22", id: "x3"))
    }

    /// 同日 id AAA→AAB（字典序推进）
    func test_idMonotonicWithinDay() {
        XCTAssertTrue("AAA" < "AAB")  // 字典序前提
        let cur = MovieCursor(phase: .same, date: "2024-06-22", id: "AAA")
        let next = WarmCursor.advance(cur, lastDate: "2024-06-22", lastId: "AAB")
        XCTAssertEqual(next, MovieCursor(phase: .same, date: "2024-06-22", id: "AAB"))
    }

    /// "same"/"tail"/"null"/"done" → 对应相位；"" 与 nil（及 "head"/未知串）回落 TAIL（旧数据兼容）
    func test_phaseOf_mapsPersistedStrings() {
        XCTAssertEqual(WarmCursor.phaseOf("same"), .same)
        XCTAssertEqual(WarmCursor.phaseOf("tail"), .tail)
        XCTAssertEqual(WarmCursor.phaseOf("null"), .null)
        XCTAssertEqual(WarmCursor.phaseOf("done"), .done)
        // 旧数据/非法持久态兜底：""、nil、"head"、其他未知串 → TAIL
        XCTAssertEqual(WarmCursor.phaseOf(""), .tail)
        XCTAssertEqual(WarmCursor.phaseOf(nil), .tail)
        XCTAssertEqual(WarmCursor.phaseOf("head"), .tail)
        XCTAssertEqual(WarmCursor.phaseOf("bogus"), .tail)
    }

    /// 四相位 phaseStr→phaseOf 往返恒等（HEAD 态从不持久化读回，不在往返集合内）
    func test_phaseStr_roundTrips() {
        let persisted: [MoviePhase] = [.same, .tail, .null, .done]
        for p in persisted {
            XCTAssertEqual(WarmCursor.phaseOf(WarmCursor.phaseStr(p)), p, "相位 \(p) 应往返恒等")
        }
        // 持久化字符串形态即 rawValue
        XCTAssertEqual(WarmCursor.phaseStr(.same), "same")
        XCTAssertEqual(WarmCursor.phaseStr(.tail), "tail")
        XCTAssertEqual(WarmCursor.phaseStr(.null), "null")
        XCTAssertEqual(WarmCursor.phaseStr(.done), "done")
    }
}
