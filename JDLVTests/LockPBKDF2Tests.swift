//
//  LockPBKDF2Tests.swift
//  JDLVTests
//
//  对应规格: docs/_extract/10_misc_pages.md §8（启动锁）—— PBKDF2 凭据哈希与失败锁定计数器。
//  被测: JDLV.LockSecrets（PBKDF2-HMAC-SHA256/CommonCrypto、iOS 新格式
//        pbkdf2-sha256$<iter>$<salt_b64>$<hash_b64>、Android 旧格式兼容、裸 sha256、
//        恒定时间比较）与 JDLV.LockThrottle（5 次/30s/×2 指数封顶 32 分，注入时钟）。
//
//  说明: CommonCrypto 仅 iOS 可用，故本套件放 JDLVTests（宿主 App 目标），不进 JDLVCoreTests。
//

import XCTest
@testable import JDLV

final class LockPBKDF2Tests: XCTestCase {

    // MARK: - PBKDF2 已知向量（RFC 风格标准向量）

    /// PBKDF2-HMAC-SHA256 标准向量：P="secret", S="salt"
    /// c=1 → 120fb6cf...；c=2 → ae4d0c95...；c=4096 → c5e478d5...
    func test_pbkdf2KnownVectors() {
        let salt = Data("salt".utf8)
        func hexOf(_ plain: String, _ rounds: Int) -> String {
            LockSecrets.pbkdf2(plain: plain, salt: salt, rounds: rounds, keyLength: 32)
                .map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(
            hexOf("secret", 1),
            "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        XCTAssertEqual(
            hexOf("secret", 2),
            "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
        XCTAssertEqual(
            hexOf("secret", 4096),
            "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
    }

    // MARK: - hashSecret/verifySecret 自洽往返

    /// hashSecret 格式：pbkdf2-sha256$120000$<salt_b64 16B>$<hash_b64 32B>；verify 往返
    func test_hashSecretFormatAndRoundTrip() {
        let stored = LockSecrets.hashSecret("secret")
        XCTAssertTrue(stored.hasPrefix("pbkdf2-sha256$120000$"), "格式前缀+默认迭代数")
        let parts = stored.split(separator: "$").map(String.init)
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts[0], "pbkdf2-sha256")
        XCTAssertEqual(parts[1], "120000")
        let salt = Data(base64Encoded: parts[2])
        let hash = Data(base64Encoded: parts[3])
        XCTAssertNotNil(salt)
        XCTAssertNotNil(hash)
        XCTAssertEqual(salt?.count, 16, "随机盐 16B")
        XCTAssertEqual(hash?.count, 32, "256 位输出")
        // 自洽往返
        XCTAssertTrue(LockSecrets.verifySecret("secret", stored: stored))
        XCTAssertFalse(LockSecrets.verifySecret("Secret", stored: stored))   // 大小写敏感
        XCTAssertFalse(LockSecrets.verifySecret("", stored: stored))
    }

    /// 错误口令不匹配；同明文两次哈希（随机盐）密文不同但都能验证
    func test_verifyWrongSecretAndRandomSalts() {
        let a = LockSecrets.hashSecret("secret")
        let b = LockSecrets.hashSecret("secret")
        XCTAssertNotEqual(a, b, "随机盐 → 同明文不同密文")
        XCTAssertTrue(LockSecrets.verifySecret("secret", stored: a))
        XCTAssertTrue(LockSecrets.verifySecret("secret", stored: b))
        XCTAssertFalse(LockSecrets.verifySecret("wrong-secret", stored: a))
    }

    // MARK: - Android 旧格式兼容（三端互认）

    /// pbkdf2:<iter>:<saltHex>:<hashHex> 与 pbkdf2:<iter>:<len>:<saltHex>:<hashHex> 可验证
    func test_verifyAndroidLegacyPbkdf2Formats() {
        let salt = Data((0..<16).map { UInt8($0) })
        let hash = LockSecrets.pbkdf2(plain: "secret", salt: salt, rounds: 120_000, keyLength: 32)
        let saltHex = salt.map { String(format: "%02x", $0) }.joined()
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()

        let noLen = "pbkdf2:120000:\(saltHex):\(hashHex)"
        XCTAssertTrue(LockSecrets.verifySecret("secret", stored: noLen))
        XCTAssertFalse(LockSecrets.verifySecret("wrong", stored: noLen))
        XCTAssertEqual(LockSecrets.secretLength(noLen), 0)

        let withLen = "pbkdf2:120000:6:\(saltHex):\(hashHex)"
        XCTAssertTrue(LockSecrets.verifySecret("secret", stored: withLen))
        XCTAssertEqual(LockSecrets.secretLength(withLen), 6, "旧格式可读出原文长度")

        // 坏格式 → false
        XCTAssertFalse(LockSecrets.verifySecret("secret", stored: "pbkdf2:abc:zz:zz"))
        XCTAssertFalse(LockSecrets.verifySecret("secret", stored: "pbkdf2:120000:zz:zz"))
    }

    /// 更旧：64 位裸 sha256 hex（sha256("secret") 已知值）
    func test_verifyBareSha256Legacy() {
        let stored = "5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8"
        XCTAssertTrue(LockSecrets.verifySecret("secret", stored: stored))
        XCTAssertFalse(LockSecrets.verifySecret("wrong", stored: stored))
        XCTAssertEqual(LockSecrets.secretLength(stored), 0)
        // 非 hex / 长度不符 → false
        XCTAssertFalse(LockSecrets.verifySecret("secret", stored: String(repeating: "z", count: 64)))
        XCTAssertFalse(LockSecrets.verifySecret("secret", stored: "abc"))
    }

    /// secretLength：新格式 0（走防抖）；乱串 0
    func test_secretLengthOfNewFormatIsZero() {
        XCTAssertEqual(LockSecrets.secretLength(LockSecrets.hashSecret("secret")), 0)
        XCTAssertEqual(LockSecrets.secretLength(""), 0)
        XCTAssertEqual(LockSecrets.secretLength("junk"), 0)
    }

    /// 恒定时间比较：相等/单字节差异/长度不等
    func test_constantTimeEquals() {
        let a = Data([0x01, 0x02, 0x03])
        XCTAssertTrue(LockSecrets.constantTimeEquals(a, Data([0x01, 0x02, 0x03])))
        XCTAssertFalse(LockSecrets.constantTimeEquals(a, Data([0x01, 0x02, 0x04])))
        XCTAssertFalse(LockSecrets.constantTimeEquals(a, Data([0x01, 0x02])))
        XCTAssertTrue(LockSecrets.constantTimeEquals(Data(), Data()))
    }

    // MARK: - 失败锁定计数器（注入时钟）

    /// 罚时长表：5 次→30s，×2 指数，shift 封顶 6 → 32 分钟
    func test_penaltyTable() {
        XCTAssertEqual(LockThrottle.penaltyMs(fails: 0), 0)
        XCTAssertEqual(LockThrottle.penaltyMs(fails: 4), 0)
        XCTAssertEqual(LockThrottle.penaltyMs(fails: 5), 30_000)
        XCTAssertEqual(LockThrottle.penaltyMs(fails: 6), 60_000)
        XCTAssertEqual(LockThrottle.penaltyMs(fails: 7), 120_000)
        XCTAssertEqual(LockThrottle.penaltyMs(fails: 8), 240_000)
        XCTAssertEqual(LockThrottle.penaltyMs(fails: 9), 480_000)
        XCTAssertEqual(LockThrottle.penaltyMs(fails: 10), 960_000)
        XCTAssertEqual(LockThrottle.penaltyMs(fails: 11), 1_920_000, "32 分钟")
        XCTAssertEqual(LockThrottle.penaltyMs(fails: 12), 1_920_000, "封顶 32 分钟")
        XCTAssertEqual(LockThrottle.penaltyMs(fails: 50), 1_920_000)
    }

    /// 连续失败 <5 不锁定；第 5 次锁 30s；锁定期内 checkLocked 为真、剩余毫秒正确
    func test_fiveFailsLockFor30Seconds() {
        var t = 1_000.0
        let throttle = LockThrottle(clock: { t })
        for _ in 0..<4 {
            let penalty = throttle.registerFailure()
            XCTAssertEqual(penalty, 0)
            XCTAssertFalse(throttle.checkLocked())
        }
        XCTAssertEqual(throttle.fails, 4)
        let fifth = throttle.registerFailure()
        XCTAssertEqual(fifth, 30_000)
        XCTAssertEqual(throttle.fails, 5)
        XCTAssertTrue(throttle.checkLocked())
        XCTAssertEqual(throttle.remainingMs(), 30_000)
        // 半分钟后仍锁（25s 处）
        t += 15
        XCTAssertTrue(throttle.checkLocked())
        XCTAssertEqual(throttle.remainingMs(), 15_000)
    }

    /// 倒计时结束：checkLocked 解除并归零 fails（重计）
    func test_lockExpiryResetsFails() {
        var t = 0.0
        let throttle = LockThrottle(clock: { t })
        for _ in 0..<5 { throttle.registerFailure() }
        XCTAssertTrue(throttle.checkLocked())
        t += 30.5
        XCTAssertFalse(throttle.checkLocked())
        XCTAssertEqual(throttle.fails, 0)
        XCTAssertEqual(throttle.remainingMs(), 0)
        // 归零后重新累计：前 4 次不锁
        for _ in 0..<4 {
            throttle.registerFailure()
            XCTAssertFalse(throttle.checkLocked())
        }
    }

    /// 指数增长路径：不经历倒计时结束的连续失败 → 6 次罚 60s … 11 次封顶 32 分钟
    func test_exponentGrowsAndCaps() {
        var t = 0.0
        let throttle = LockThrottle(clock: { t })
        var lastPenalty = 0
        for fails in 1...12 {
            lastPenalty = throttle.registerFailure()
            if fails < 5 {
                XCTAssertEqual(lastPenalty, 0)
            } else {
                XCTAssertEqual(lastPenalty, LockThrottle.penaltyMs(fails: fails))
            }
        }
        XCTAssertEqual(lastPenalty, 1_920_000, "第 12 次仍封顶 32 分钟")
        XCTAssertEqual(throttle.remainingMs(), 1_920_000)
    }

    /// reset 清零（解锁成功路径）
    func test_reset() {
        var t = 0.0
        let throttle = LockThrottle(clock: { t })
        for _ in 0..<5 { throttle.registerFailure() }
        XCTAssertTrue(throttle.checkLocked())
        throttle.reset()
        XCTAssertFalse(throttle.checkLocked())
        XCTAssertEqual(throttle.fails, 0)
        XCTAssertEqual(throttle.remainingMs(), 0)
    }
}
