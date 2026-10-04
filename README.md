# TallyNest / 小记

SwiftUI + SwiftData 的 iPhone、iPad 和 Mac 待办与财务应用。当前本地开发版本：**1.0（69）**。当前已上传的 TestFlight 版本仍为 **67**；修改代码不会自动更新 TestFlight。

## 69 版维护更新

- 任务、清单保存前核对编辑快照，拒绝覆盖其他窗口的新内容或重新创建已删除对象；保留未保存输入。
- 已有预算或账单时锁定本位币；编辑和恢复草稿不会因为后台数据刷新而改变金额单位。
- 汇率缓存读写与解析离开主线程，并合并并发请求；资产余额改为一次遍历计算。
- 普通任务行、统计分类各自管理展开状态，保留原有界面与日任务原位展开。
- 增加分代升级快照、固定旧库回归和发布签名／崩溃符号检查；建立本地 Git 基线。

2026-10-05 验证：14 个检查阶段通过，Mac 1,265 项与模拟器 1,167 项自检通过；固定 68 版旧库运行共 1,277 项检查。Mac 两种架构、模拟器和 iPhone 目标编译通过，无源代码并发警告。100 账户、5,000 账单同次运行：余额扫描由 73.6 ms 降到 2.2 ms，结果相同；这不是帧率测量。模拟器核对了任务展开／收起、子任务、普通列表及财务三页。日志在工作区 `检查证据/长期维护加固-69-20261004`；69 尚未归档上传，真机流畅度与双机同步仍需验收。

## 工程与版本记录

- 唯一开发源：`.`。
- 打开此目录的 `Jianshi.xcodeproj`。桌面 `软件/简事` 仅作为源码镜像，避免两边各改一份；需要修改时回到开发源。
- 本地 Git 已记录 `baseline-1.0-68`。Git 用于提交、比较和回退；GitHub 是可选的远程托管服务。本项目目前没有配置远程仓库。
- Git 不包含用户数据库、导出备份、证书、私钥、编译产物或发布包；`Checks/Fixtures` 中明示的合成测试库除外。
- 不使用旧构建打开新版真实数据。需要对比旧代码时，在独立测试标识及合成数据环境运行。

## 构建与运行

需要 macOS、Xcode（含 iOS SDK 与模拟器）和系统 Python 3。

- 本地调试：选择 `Jianshi` scheme 和目标设备。
- App Store 构建：选择 `Jianshi-AppStore` scheme；Mac 的该 scheme 以非调试方式运行，归档使用 AppStore 配置。
- 日常自检无需分发签名、App Store Connect 登录或云端数据。不要为消除警告关闭并发检查。

## 一次运行完整检查

在工程目录运行，指定一台可用的 iPhone 模拟器：

```sh
xcrun simctl list devices available
python3 Checks/verify.py --simulator <模拟器UDID> --performance
```

结果与日志默认保存在 `.build/verification/`，可用 `--output /path/to/logs` 指定位置。流程逐项执行：

1. Mac（Apple Silicon 与 Intel）、iOS 模拟器和 iPhone 设备目标干净编译，严格并发检查；源代码警告会使检查失败。
2. 三端包内隐私声明、加密声明及禁用组件检查。
3. Mac 与模拟器功能自检；任务和清单并发编辑、财务币种及数据恢复回归。
4. 固定 68 版合成数据库升级、完整记录与同步基线核对。
5. 账户切换币种检查；可选的 5,000 项数据性能测量。

检查使用临时构建目录、临时数据库和独立模拟器应用标识，完成后移除测试应用。不会连接真实 CloudKit 或启动正常应用的数据加载流程。若运行中源码变化，检查会失败，必须重跑。

这些检查不包含真机帧率、系统手势、真实推送、双设备 iCloud 往返同步或 App Store 审核。发布前仍需真机验收。

## 数据与维护约定

- 保存入口：任务、清单经 `Store.save`；财务经 `FinanceStore.update`。保持保存失败回滚、草稿保留及恢复锁定。
- 编辑器持有打开时的值快照；保存前重新核对。在 `await` 之后必须再次核对，避免覆盖其他窗口刚保存或删除的内容。
- 本位币是金额含义的一部分。已有账单或预算时不可仅修改币种代码；编辑中的输入也不可随后台刷新被解释为另一种币种。
- 修改 SwiftData 持久化结构前，更新 `StoreUpgradeSnapshot.generation`，保留旧代际快照。不要删除现有备份或沿用旧代际名。
- 保留 `Checks/Fixtures/schema-68` 的冻结库及哈希。未来新增旧版本测试库，不在每次测试时用当前模型重新生成。当前固定测试边界从 68 开始，更早已发布结构仍需单独补充。
- iCloud 数据格式修改须另行核对兼容性及 `TaskBackup` 版本保护；本次 69 未改变云端格式。
- 大列表的展开状态放到各自的行或分类子视图；不要在页面根层监听每一项展开状态。大量计算、网络与缓存磁盘处理避免占用 UI 主线程。
- 当前仍使用 Swift 5 语言模式，同时启用完整并发检查和 `InferSendableFromCaptures`。未来切换 Swift 6 时应单独做兼容性验证。

## 发布检查

1. 功能修改完成后运行完整检查，审阅差异并提交本地 Git。
2. 增加构建号，分别归档 iOS 和 macOS，再按 App Store Connect 配置导出。
3. 对**最终导出的应用**及其对应归档的 dSYM 执行：

```sh
python3 Checks/check_release_bundle.py /path/to/小记.app \
  --production --dsym /path/to/小记.app.dSYM --build <构建号>
```

该命令验证正式签名、Production CloudKit、容器与团队、禁用调试权限、Mac 沙盒以及崩溃符号 UUID。本地未签名编译通过不等于这些发布检查通过。

4. 保存源代码提交号、两端归档、dSYM、最终安装包及检查日志，再上传并核对 TestFlight 构建号。
5. 在真机验证启动、任务展开/快速滚动、财务三页、编辑保存及取消、双设备同步。外部测试仍以 Apple 审核状态为准。

## 主要代码位置

| 文件 | 主要职责 |
| --- | --- |
| `Models.swift` | 本地模型、存储保护、备份与日期规则 |
| `TaskEditor.swift` / `EditingChecks.swift` | 任务与清单编辑、保存冲突检查及回归 |
| `ContentView.swift` / `DayTimeline.swift` | 导航、日周月日历与任务显示 |
| `FinanceModels.swift` / `FinanceView.swift` | 账本规则、汇率及财务显示 |
| `CloudSync.swift` | iCloud 同步、冲突合并及协议保护 |
| `SelfCheck.swift` / `FinanceChecks.swift` | 合成数据验证及性能检查 |
| `Checks/` | 统一检查入口、发布包检查及冻结数据 |

ContentView 与 FinanceView 仍较大，后续按实际功能改动逐步拆分；优先明确状态和数据边界，不做只搬文件的重构。历史修复和当时的验收记录见 [CHANGELOG.md](CHANGELOG.md)。
