import XCTest
@testable import JDLV
import JDLVCore

//
//  CdnFallbackTests.swift —— R7-P5（任务 06）图床回退矩阵。
//
//  覆盖：
//  - jdbImgUrl /avatars/ 强制 APP CDN（app/web/自定义镜像 × http/https × 完整/裸路径）;
//  - covers 不强制（跟随用户图床选择）;
//  - altJdbImgUrl app↔web 互换（transport 回退的目标生成）;
//  - FailedURLCache 30s 负缓存（拦截/过期惰性放行/clear 手动重试放行）。
//
//  transport→alt 的网络行为无法在本套件 mock（ImagePipeline 持真实 URLSession），
//  由真机/远程库验证（p5 证据 + BLOCKED(ENV) 记录）。
//
final class CdnFallbackTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CdnRewrite.settingsProvider = { CdnSettings() }   // 默认 app 图床 + 无代理
    }

    // MARK: - 步骤 2：avatars 强制 APP CDN

    func testAvatarsForcedToAppCdnFromWebUrl() {
        XCTAssertEqual(
            CdnRewrite.jdbImgUrl("https://c0.jdbstatic.com/avatars/ab/abc.jpg"),
            "https://tp.spfcas.com/rhe951l4q/avatars/ab/abc.jpg")
    }

    func testAvatarsForcedToAppCdnFromHttpUrl() {
        XCTAssertEqual(
            CdnRewrite.jdbImgUrl("http://c0.jdbstatic.com/avatars/ab/abc.jpg"),
            "https://tp.spfcas.com/rhe951l4q/avatars/ab/abc.jpg")
    }

    func testAvatarsForcedToAppCdnFromBarePath() {
        XCTAssertEqual(
            CdnRewrite.jdbImgUrl("/avatars/ab/abc.jpg"),
            "https://tp.spfcas.com/rhe951l4q/avatars/ab/abc.jpg")
    }

    func testAvatarsForcedEvenWhenUserPicksWeb() {
        CdnRewrite.settingsProvider = { CdnSettings(jdbImgHost: "web") }
        XCTAssertEqual(
            CdnRewrite.jdbImgUrl("https://c0.jdbstatic.com/avatars/ab/abc.jpg"),
            "https://tp.spfcas.com/rhe951l4q/avatars/ab/abc.jpg",
            "web 设置下头像仍强制 APP CDN（c0 无代理不可达 → 头像全灭根因）")
    }

    func testAvatarsForcedEvenWhenUserSetsCustomMirror() {
        CdnRewrite.settingsProvider = { CdnSettings(jdbImgHost: "https://mirror.example.com") }
        XCTAssertEqual(
            CdnRewrite.jdbImgUrl("/avatars/ab/abc.jpg"),
            "https://tp.spfcas.com/rhe951l4q/avatars/ab/abc.jpg",
            "自定义镜像下头像同样强制 APP CDN")
    }

    // MARK: - covers 不强制（跟随用户设置）

    func testCoversFollowUserSetting() {
        XCTAssertEqual(
            CdnRewrite.jdbImgUrl("https://c0.jdbstatic.com/covers/ab/abc.jpg"),
            "https://tp.spfcas.com/rhe951l4q/covers/ab/abc.jpg",
            "默认 app: c0 封面重写到 spfcas")
        CdnRewrite.settingsProvider = { CdnSettings(jdbImgHost: "web") }
        XCTAssertEqual(
            CdnRewrite.jdbImgUrl("https://c0.jdbstatic.com/covers/ab/abc.jpg"),
            "https://c0.jdbstatic.com/covers/ab/abc.jpg",
            "web 设置: 封面留在 c0（与头像不同, 封面多为 spfcas 系直连可达）")
    }

    // MARK: - altJdbImgUrl 互换（transport 回退目标）

    func testAltSwapsAppToWebAndBack() {
        XCTAssertEqual(
            CdnRewrite.altJdbImgUrl("https://tp.spfcas.com/rhe951l4q/avatars/ab/abc.jpg"),
            "https://c0.jdbstatic.com/avatars/ab/abc.jpg")
        XCTAssertEqual(
            CdnRewrite.altJdbImgUrl("https://c0.jdbstatic.com/avatars/ab/abc.jpg"),
            "https://tp.spfcas.com/rhe951l4q/avatars/ab/abc.jpg")
    }

    // MARK: - 步骤 3：负缓存

    func testNegativeCacheBlocksFor30sThenReleases() {
        let c = FailedURLCache()
        let t0 = Date()
        c.mark("u1", at: t0)
        XCTAssertTrue(c.isBlocked("u1", now: t0.addingTimeInterval(29)), "TTL 内拦截")
        XCTAssertFalse(c.isBlocked("u1", now: t0.addingTimeInterval(31)), "TTL 30s 后放行")
    }

    func testNegativeCacheClearAllowsManualRetry() {
        let c = FailedURLCache()
        c.mark("u2")
        XCTAssertTrue(c.isBlocked("u2"))
        c.clear("u2")
        XCTAssertFalse(c.isBlocked("u2"), "clear（手动重试 retryKey）后放行")
    }

    func testNegativeCacheUnknownUrlNotBlocked() {
        let c = FailedURLCache()
        XCTAssertFalse(c.isBlocked("never-failed"))
    }
}
