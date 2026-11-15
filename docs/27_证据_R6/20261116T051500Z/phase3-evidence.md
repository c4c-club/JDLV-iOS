# R6 任务 04（PHASE3 布局与 98t 筛选）证据

日期：2026-11-16（UTC 2026-11-15 晚起跑的 CI）
任务文件：docs/26_分段执行_R6/04_PHASE3_布局与98t筛选.md

## 1. 改前证据（缺陷实况）

来源：R5 收尾 CI run `20261112T203823Z`（docs/24_证据_R5/20261112T203823Z/ci/）。

- 数值铁证 `att-j1/dump-card_browse_0.txt`：402pt 宽屏幕上 browse 两列卡片
  宽 139pt，行左缘 15.5、右缘 304.5 → 右侧空白 ≈ 97.5pt。
  （139 = (320−32−12)/2：容器宽实测失效，恒走 320 兜底。）
- 视觉证据 `attachments/03-browse.png`、`06-actors.png`、`08-sht.png`：右侧大块空白。
- 根因：PageScaffold 深处 ScrollView 上的 `.preference(PageContainerWidthKey)`
  冒泡到页面级 `.onPreferenceChange` 实测不可达；R5 布局审计只断言卡内等宽，
  测不出该缺陷（其 layout-report.json 为空 violations）。

## 2. 修复内容（commit d98625e 起）

- 统一容器宽策略：新增 `ContainerWidthReader`（UI/Common/CardGrid.swift），
  走 PageScaffold 注入的 `environment(\.containerWidth)` 向下通道，放进页面
  content 即取实测宽（首帧即真值）；resolvedContainerWidth 兜底口径不变。
- 四页接入：BrowseView / ActorsView / ShtView / HomeView（browse、actors、98t
  网格 + 首页三段大图/结果区）；ShtView 同时删除 UIScreen.main.bounds 口径
  （与 BrowseView 统一）。页面级 onPreferenceChange(PageContainerWidthKey) 移除。
- 98t 主版筛选：ShtVM.loadCats 远程失败/空 mains → 静态兜底
  （FALLBACK_MAINS，口径=应用自述版区结构）；兜底不写缓存，远端恢复即覆盖；
  bind 不再以首屏成功为前提（离线同样加载分类）；sheet 显示来源与加载中，
  c=0 行只显版区名。
- 布局审计防回归：LayoutAuditUITests.audit 增 checkFullWidth/fullWidthMargin ——
  断言行内容左缘≈边距、右缘≈屏宽−边距（±3pt）；接入 browse/actors/sht/
  articles（16pt）与 hot-reviews（全出血 margin=0，CI 实测口径）。
- 顺带修复（CI 暴露）：
  - ImageLoading 协议符合（d40b02a）：ticket 默认参使 5 参签名不再是 4 参
    witness；拆分 witness + ticketed 方法；ZoomableImage 补 maxPixel:0。
  - InflightGate 去重竞态（d9f45d9）：锁外 makeEntry+双检窗口内输者任务
    被 cancel 但 body 不感知取消照样执行（计数 2≠1）→ 改锁内装配入字典。
  - hot-reviews 满宽口径（7ad7bbb）：行卡全出血，10pt 是卡内文本边距。

## 3. 新增测试

- ShtVMTests（VM 层）：
  - testLoadCatsFallsBackToStaticBoardsWhenRemoteThrows（远程失败 → 兜底）
  - testLoadCatsFallsBackWhenRemoteReturnsEmptyMains（空 mains → 兜底且不写缓存）
  - testRemoteCatsOverrideFallbackSource（远端成功 → remote 覆盖）
  - testBindLoadsCatsEvenWhenListFails（首屏失败也加载分类）
  - testSelectingMainCarriesQueryParamsAndResetsPage（选项>0 且可点选：
    setMain → 查询参数携带 main、级联清空、page=1；兜底选项同样可点选）
- ShtFilterSheetUITests（UI 层）：真实 sheet 打开 → 主版 Picker → 选项行
  「有码中文字幕」存在并可点选 → 关闭后列表恢复。
- InflightGateTests 既有用例在修复后恢复通过（并发 10 → body 执行 1 次）。

## 4. CI 轨迹（repo c4c-club/JDLV-iOS，workflow ios）

| run | head | 结果 | 说明 |
|-----|------|------|------|
| 43741838626 | d98625e | ios Build FAIL | ImageLoading witness 缺失（PHASE2 潜伏） |
| 43742902168 | d40b02a | Test FAIL + 布局门禁 FAIL | 2 处：hot-reviews 边距口径（本任务缺陷已修）+ InflightGate 竞态/ShtVM 离线测试注入缺 catsError |
| 43749476682 | 7ad7bbb | Test FAIL（仅 2 单测） | InflightGate 去重竞态 + 离线分类测试漏 catsError；布局门禁通过（仅 hot-reviews 2 条，见下） |
| 43755497265 | d9f45d9 | Test/截图/布局门禁 PASS；IPA 门禁 FAIL | IPA 明细未输出（verify_ipa.py 只打 verdict） |
| 43763473239 | 1d0f180 | （诊断盲区修复后重跑） | verify_ipa.py FAIL 时全量明细进日志 + 报告随产物上传 |

## 5. 改后证据（ci-after/）

来自 run 43749476682（布局代码与本任务最终态一致；hot-reviews 口径修正
7ad7bbb 后布局断言全绿在 43755497265 复证）：

- `ci-after/layout-report-run43749476682.json`：violations 仅 hot-reviews 2 条
  （margin 口径修正项，非页面缺陷）；browse/actors/sht/articles 全部通过满宽
  断言（左缘 16、右缘 402−16 ±3pt）。hot-reviews 行卡实测全出血
  （minX=−0.5 / maxX=402.5）→ 口径修正为 margin=0。
- `ci-after/03-browse.png`：两列卡片铺满 402pt 屏（16pt 边距），右侧空白消除。
- `ci-after/08-sht.png`：98t 搜索条与两列卡片铺满，右侧空白消除。
- `ci-after/06-actors.png`：女优三列铺满。
- `ci-after/11-hot-reviews.png`：热评行卡（全出血口径）。
- `ci-after/manifest.json`：17 张截图清单（截图门禁 PASS，--min 16 满足）。

## 6. 门禁输出（本地复跑）

- `bash scripts/guard_repo.sh` → guard OK（hits=48 全部分类，MANIFEST-GATE OK）。
- `python -I scripts/scan_repo_secrets.py --mode head` + check_hits_manifest →
  MANIFEST-GATE OK（48 hits / 37 unique / 72 manifest entries）。
- `verify_ipa.py` 对 PHASE0 证据包：syn-clean.ipa → PASS（byte_hits=0）；
  syn-dirty.ipa → FAIL（负对照有效）。

## 7. 真机项

无 Mac/iPhone 设备 → 任务 04 不含需真机复验项；布局几何证据全部来自 CI
模拟器（iPhone 17 Pro, iOS 26.2, 402×874pt）。实机项统一在任务 05 处理
（无设备则 BLOCKED(ENV)）。
