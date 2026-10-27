# 开发与验证

本页保留构建、检查和维护说明。发布状态以 [README](README.md) 为准；历史验收不替代本轮验证。

## 工程与版本记录

- 唯一开发源：本 `DEVELOPMENT.md` 所在的 Git 仓库根目录。
- 打开此目录的 `Jianshi.xcodeproj`；整理前的 `软件/Tally` 和 `软件/简事` 不再作为开发入口。
- 本机配套资料位于仓库上一级的 `发布资料/`、`宣传素材/`、`检查证据/`、`历史归档/` 和 `设计原型/`，不随本仓库发布。上一级 `网站/` 中的旧副本仅作历史参考；当前网站源文件以本仓库为准。
- 本地 Git 已记录 `baseline-1.0-68`。TallyNest 的 App 源码、支持网站和隐私页面统一维护于 [jackhuangzihao/xiaojitally-support](https://github.com/jackhuangzihao/xiaojitally-support)，默认分支为 `main`。保留此仓库名称是为了维持 App 和 App Store 已使用的支持及隐私网址。
- Git 不包含用户数据库、导出备份、证书、私钥、编译产物或发布包；`Checks/Fixtures` 中明示的合成测试库除外。
- 不使用旧构建打开新版真实数据。需要对比旧代码时，在独立测试标识及合成数据环境运行。

## 支持与隐私网站

网站源文件与 App 源码位于同一仓库：中文页面为 `index.html`、`privacy.html`，英文页面位于 `en/`；样式为 `style.css`，图片位于 `assets/` 及根目录的 `app-icon.png`。

GitHub Pages 从 `main` 分支根目录发布，保留 `.nojekyll`。推送此分支会触发网站发布；网站修改应在本仓库完成，不再编辑上一级的历史网站副本。现有中英文支持和隐私网址保持不变。网站发布不会上传或更新 App Store 的应用构建。

仓库分享封面保存在 [social-preview.jpg](assets/readme/social-preview.jpg)（1280 × 640）。更换后还需在 GitHub 仓库 `Settings → General → Social preview` 上传该图；只推送图片文件不会自动更新分享封面。

## 构建与运行

已验证的工具环境为 **Xcode 26.6（17F113）**、macOS 和系统 Python 3；工程使用 Swift 5 语言模式。部署目标为 iOS / iPadOS 17、macOS 14。完整检查还需要安装对应的 iPhone 模拟器运行时。

### 获取与打开工程

```sh
git clone https://github.com/jackhuangzihao/xiaojitally-support.git
cd xiaojitally-support
open Jianshi.xcodeproj
```

Xcode 的 `Settings → Locations → Command Line Tools` 应选择正在使用的 Xcode。可用 `xcodebuild -version` 核对；首次运行 Xcode 时，先由使用者完成必要的系统安装和许可步骤。

自行签名运行前，需使用自己的开发者团队，并对应配置应用标识、App Group 和 iCloud 容器；仓库中的原项目标识不授予作者账号或云容器的访问权。StoreKit 本地测试配置位于 `Checks/StoreKit/TallyPro.storekit`，不会自动创建或配置 App Store Connect 商品。仓库不包含开发者私钥、签名证书或商店账号凭据。

- 本地调试：选择 `Jianshi` scheme 和目标设备。
- App Store 构建：选择 `Jianshi-AppStore` scheme；Mac 的该 scheme 以非调试方式运行，归档使用 AppStore 配置。
- 日常自检无需分发签名、App Store Connect 登录或云端数据。不要为消除警告关闭并发检查。

### 先验证源码能否编译（无需分发签名）

以下命令与统一检查中的 Mac 编译参数一致，使用临时目录和独立检查身份，只编译、不启动应用：

```sh
tally_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/tally-source-build.XXXXXX")"
xcodebuild -project Jianshi.xcodeproj \
  -scheme Jianshi-AppStore -configuration AppStore \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$tally_build_dir" \
  CODE_SIGNING_ALLOWED=NO \
  PRODUCT_BUNDLE_IDENTIFIER=local.jianshi.sandboxcheck.readme \
  SWIFT_STRICT_CONCURRENCY=complete ONLY_ACTIVE_ARCH=NO build
```

看到 `BUILD SUCCEEDED` 表示源码编译通过。该产物用于检查，不能直接当成正式安装包或商店版运行；应用内自检请使用下方的统一隔离检查入口。

### 使用自己的开发者身份签名运行

在自己的克隆或 fork 中修改配置，使用新标识与官方 App 区分。以下是需要保持一致的位置；不要把团队标识误当成私钥或使用作者的云容器测试。

| 配置 | Xcode / 文件位置 | 需要核对的内容 |
| --- | --- | --- |
| 开发者团队与应用标识 | `Jianshi` target 的 `Signing & Capabilities`；[project.pbxproj](Jianshi.xcodeproj/project.pbxproj) | 各构建配置的 `DEVELOPMENT_TEAM`、`PRODUCT_BUNDLE_IDENTIFIER` 使用自己的团队与唯一标识。 |
| iCloud 权限 | [JianshiCloud.entitlements](JianshiCloud.entitlements)、[JianshiMac.entitlements](JianshiMac.entitlements)、[JianshiStore.entitlements](JianshiStore.entitlements) | `com.apple.developer.icloud-container-identifiers` 使用自己配置的 CloudKit 容器；核对目标平台实际使用的权限文件。 |
| 运行时云容器 | [CloudSync.swift](Sources/Storage/Sync/CloudSync.swift) 的 `CloudSync.containerID` | 必须与上述 iCloud 权限里的容器标识一致；只改签名页不会同步修改这里。 |
| App Group 与小组件 | [JianshiMac.entitlements](JianshiMac.entitlements)、[Widget.entitlements](Widget/Widget.entitlements)、[WidgetShared.swift](Sources/Shared/WidgetShared.swift) 的 `WidgetSnapshot.group` | 如使用相关能力，组标识必须属于自己的团队并保持一致。当前小组件未启用，单独改组标识不会启用小组件。 |
| 应用内购买 | [StoreKit 本地配置](Checks/StoreKit/TallyPro.storekit)、[ProAccess.swift](Sources/Purchases/ProAccess.swift) | 本地配置只用于 StoreKit 测试；正式购买还需自己的 App Store Connect 商品、签名及匹配商品标识。 |

完成自己的签名与能力配置后，再选 `Jianshi` scheme 和自己的测试设备运行，并只使用合成示例数据。首次启动保持 iCloud 同步关闭；真实账号同步需要另外核对自己的容器与数据备份。正式发布按本文“发布检查”执行。

## 一次运行完整检查

在工程目录运行，指定一台可用的 iPhone 模拟器：

```sh
xcrun simctl list devices available
python3 Checks/verify.py --simulator <模拟器UDID> --performance
```

结果与日志默认保存在 `.build/verification/`，可用 `--output /path/to/logs` 指定位置。流程逐项执行：

1. 核对源码实际路径、Xcode 编译引用与重复引用，再进行 Mac（Apple Silicon 与 Intel）、iOS 模拟器和 iPhone 设备目标干净编译，严格并发检查；源代码警告会使检查失败。
2. 三端包内隐私声明、加密声明及禁用组件检查。
3. Mac 与模拟器功能自检；任务和清单并发编辑、财务币种及数据恢复回归。
4. 固定 52、68 两代合成数据库升级、完整记录与同步基线核对。
5. 账户切换币种检查；可选的 5,000 项数据性能测量。

检查使用临时构建目录、临时数据库和独立模拟器应用标识，完成后移除测试应用。不会连接真实 CloudKit 或启动正常应用的数据加载流程。若运行中源码变化，检查会失败，必须重跑。

这些检查不包含真机帧率、系统手势、真实推送、双设备 iCloud 往返同步或 App Store 审核。发布前仍需真机验收。

## 数据与维护约定

- 保存入口：任务、清单经 `Store.save`；独立财务操作经 `FinanceStore.update`。新建任务附带账单先完成纯值校验，再用 `FinanceStore.stage` 与任务一起经一次 `Store.save` 提交，禁止分别保存。保持保存失败回滚、草稿保留及恢复锁定。
- 编辑器持有打开时的值快照；保存前重新核对。在 `await` 之后必须再次核对，避免覆盖其他窗口刚保存或删除的内容。
- 本位币是金额含义的一部分。已有账单或预算时不可仅修改币种代码；编辑中的输入也不可随后台刷新被解释为另一种币种。统计显示偏好使用 `moneyStatsCurrency`，不得用显示设置改写已存金额。
- 预设分类通过归档从新增选项移除，保留其稳定 ID 与历史引用，避免旧版默认分类补全将其重新加入。父子分类操作继续经 `updateCategory` 校验。
- 修改 SwiftData 持久化结构前，更新 `StoreUpgradeSnapshot.generation`，保留旧代际快照。不要删除现有备份或沿用旧代际名。
- 保留 `Checks/Fixtures/schema-52`、`schema-68` 的冻结库、来源及哈希，不在每次测试时用当前模型重新生成。52 固定库验证旧模型缺少周标题表的实际升级；这两代测试不等于覆盖所有历史版本。
- 当前格式（2026-10-26 按源码核对）：备份 **15**、记账 **4**、云提交协议 **17**，数据库升级副本标记 **schema-v5**。修改格式时同步更新此行及 [CHANGELOG](CHANGELOG.md)；历史版本说明不代表当前格式。
- iCloud 数据格式修改须另行核对兼容性及 `TaskBackup` 版本保护。账户币种和相关流水必须一起合并，不能独立选择而改变金额含义。
- 同步缓存仅在 context、`Store.revision`、基线和未保存状态均匹配时复用。持久化改动继续统一经 `Store.save`；不能绕过版本递增。缓存不能替代异步操作之后和提交之前的版本检查。
- 新增财务弹窗时将其纳入 `FinanceHome.presentationActive`，避免通知导航打断输入；窗口级事件监听必须限定宿主窗口、可见区域和输入焦点，并在视图销毁时移除。
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

## 历史文档

旧报告统一放在 [资料/使用与发布说明](资料/使用与发布说明) 和 [资料/历史验收](资料/历史验收)。报告保留当时的版本与验收范围；当前版本以 [README](README.md) 开头说明为准。

维护 `CHANGELOG.md` 时一并检查它引用的 `资料/` 文档及文档间的相对链接，确认链接目标存在，不把旧报告重新复制到根目录。

历史记录中的 `检查证据/…` 对应当前仓库上一级的 `../检查证据/…`；`开发备份/…` 对应 `../历史归档/开发备份/…`。历史验证结果不代表当前代码已重新验证。

## 主要代码位置

磁盘目录与 Xcode 分组一致。仍为一个应用编译模块，没有引入新的包或依赖。

2026-10-08 完成第一阶段源码整理：主应用 65 → 81 个 Swift 文件，按完整类型与现成方法组搬移；保留访问权限、状态归属、数据格式与业务逻辑。整理前回退点为 Git 标签 `before-source-organization-20261008`（`1a5a338`）。完整 14 阶段检查通过：Mac 1,584 项、iOS 模拟器 1,497 项，包含旧库迁移、账户币种、三种构建与包检查、5,000 项数据性能检查；证据见工作区 `检查证据/源码整理实施-20261008`。本地版本仍为 1.0（76）。

| 目录 | 主要职责与入口 |
| --- | --- |
| [Sources/App](Sources/App) | `JianshiApp` 启动；`ContentView` 窗口导航和日历状态；设置、编辑草稿、侧栏交互 |
| [Sources/Tasks](Sources/Tasks) | 模型、规则、动作、提醒；`Editor/` 放任务与清单编辑器，`TaskRecurrence` 放重复任务方法 |
| [Sources/Calendar](Sources/Calendar) | 日安排 `AgendaView`、周 `WeekView`、月 `MonthView`；导航、详情与布局；`Drag/` 放拖动会话、探针和落点计算 |
| [Sources/Finance](Sources/Finance) | `Data/` 模型与规则、`Views/` 页面、`Editors/` 编辑器、`Components/` 共享视图 |
| [Sources/Storage](Sources/Storage) | `Store` 保存与恢复保护；`Backup/` 备份格式及界面；`Sync/` iCloud 同步与修改记录 |
| [Sources/Shared](Sources/Shared) | 日期与语言工具、翻页手势、共享小组件数据与桥接 |
| [Sources/Validation](Sources/Validation) | 功能、财务、编辑冲突检查；`Fixtures/` 放界面样例，`PerformanceChecks` 和 `SandboxChecks` 放现有专项检查；使用合成数据 |
| [Checks](Checks) | 统一检查入口、工程引用检查、发布包检查及冻结旧库 |

第二阶段将可独立显示的区域改为明确的输入、Binding 和操作回调，并将大型自检入口按原场景顺序提取。该阶段完成时主应用共 98 个 Swift 文件；没有增加编译模块、依赖或持久化模型。动手前的独立回退点为 `before-source-phase2-20261008`（`5002b8f`），对应 Git bundle 保存在工作区 `开发备份/源码第二阶段前-20261008`。

第二阶段完整 14 阶段检查通过：Mac 1,584 项、iOS 模拟器 1,497 项，财务 494 项和同步／存储 204 项的数量与拆分前一致。Mac 双架构、iPhone 设备与模拟器编译、包检查、52／68 冻结旧库迁移、账户币种及 5,000 项数据性能检查通过，无源代码编译警告。证据与界面抽查范围见工作区 `检查证据/源码第二阶段-20261008`；这不代表已测量真机帧率或真实双设备同步。

### 如何找修改位置

- 修改任务编辑页面：`Tasks/Editor/TaskEditor.swift` 是入口；同目录的 `TaskEditorSchedule` 管日期和重复选项，`TaskEditorFinance` 管附带账单，`TaskEditorSuggestions` 管历史建议，`TaskEditorPersistence` 管草稿与保存。
- 修改日历某种显示：先找 `Calendar/AgendaView`、`WeekView`、`MonthView`，公共导航和详情分别在 `CalendarNavigation`、`CalendarDetails`。任务变更入口在 `Tasks/TaskActions`。
- 修改侧栏、日期区或时间线外观：分别找 `App/MacWorkspaceSidebar`、`Calendar/AgendaDatePicker`、`Calendar/AgendaTimelineRows`；周任务外观在 `Calendar/WeekTaskAppearance`。显示组件不保存业务数据，仍通过原窗口或周视图的操作入口变更任务。
- 修改财务某一页：先找 `Finance/Views` 的 `FinanceEntries`、`FinanceStatisticsView`、`FinanceAssets`、`FinanceManagement`；基础账本操作在 `Finance/Data/FinanceData`，校验、汇率和示例操作在同目录的 `FinanceData+Validation`、`FinanceData+Rates`、`FinanceData+Samples`，统计规则在 `FinanceStatistics`，不要在页面另写一份规则。
- 修改账单编辑区域：`Finance/Editors/FinanceEntryEditor` 继续拥有草稿、焦点、联动和保存；`FinanceEntrySections` 显示金额、备注、标签、关联任务与分类。统计图表和分类排行分别在 `FinanceStatisticsCharts`、`FinanceStatisticsRanking`，查询和下钻导航仍由页面协调。
- 修改存储：任务仍通过 `Storage/Store` 保存，财务通过 `Finance/Data/FinanceStore` 读写同一存储；文件整理没有改变模型名称、云端格式或数据位置。
- 修改同步：`Storage/Sync/CloudSync` 拥有运行状态、缓存与网络操作，`CloudMerge` 保存原合并规则，`CloudSyncSettings` 显示状态和核对入口，原有同步检查放在 `Validation/SyncChecks`。
- 修改检查：`SelfCheck.run` 和 `FinanceChecks.run` 保留调用顺序及最终计数。日历、拖动、任务生命周期、存储、财务数据/折算/入账场景各在对应的 `*Checks` 文件里；场景显式接收 context、数据与断言闭包，不引入共享测试状态。连续操作的账本及临时目录清理仍由原入口负责。
- 修改拖动：`Calendar/Drag/WeekDrag` 保留完整周拖动会话；显示和原生探针分别在 `WeekDragViews`、`WeekDragProbes`，其他日期翻页探针在 `TaskDragPaging`，落点计算在 `CalendarDropGeometry`。

### 拆分约定

- `WeekCalendarView`、`MonthCalendarView` 是独立视图，各自私有持有拖动、弹层和重复预览缓存；周历还私有持有缩放状态。两者通过明确的只读输入、日期绑定和操作回调与窗口协调，不接收整个 `ContentView`。
- `ContentView` 保留跨页面的所选日期、复制快照、定位请求、编辑入口、保存与撤销。跨页拖动成功保存后才更新页面计数，`CalendarPageIdentity` 保持已显示页面和滚动位置；普通翻页则更换页面身份。
- 保存到拖动会话等长寿命对象的回调继续从状态所有者读取动态查询；不要把显示组件收到的数组快照保存为长期数据源。Mac 侧栏的 `configureDrag` 仅在原 `onAppear` 位置调用窗口的私有配置方法。
- 日/月安排子视图保留 ForEach 身份和每任务一行的布局，详情展开仍由 `DayTimelineCard` 自己管理；显示组件观察既有语言偏好，不复制业务状态。编辑器组件直接使用原 FocusState 的 Binding，不能新建一份焦点或草稿。
- 周/月日历退出、窗口打开其他编辑页或进入数据恢复保护时，`CalendarGridLifecycle` 关闭弹层并结束原生拖动监视；定位请求释放拖动保留的滚动位置。不要把清理放在会随翻页重建的内部网格上。
- 日视图、`FinanceHome`、`TaskEditor` 的剩余跨文件扩展仍共享各自所有者。后续按真实修改需要逐项分离；组件化本身不保证改善帧率。
- 跨文件确实需要使用的成员才采用模块内部访问；组件自己的状态与实现保持 `private`。视图输入优先使用只读值，只对确实需要双向联动的日期/改期选择使用 Binding。没有新增对外的 `public` 接口。
- 保留已有的财务 `AnyView` 页面边界及行内展开状态；它们分别用于控制真机栈大小和避免整页重复刷新。不要在拆分时顺手去掉这些保护。
- 新增/移动 Swift 文件时同步维护 Xcode 分组和 target membership；运行 `python3 Checks/check_project_sources.py` 可快速检查漏编译、重复引用和失效路径，完整检查也会自动运行它。
- 按职责拆分，不以固定行数为目标。完整的同步算法和回归场景可以保留较长文件；优先保证调用关系清晰、规则只维护一处。

历史修复和当时的验收记录见 [CHANGELOG.md](CHANGELOG.md)。

## 已知限制（暂不修复）

- **全天日期跨时区会差一天**（2026-10-10 质量检查 BUG-01）：
  - **原因**：全天任务、只有日期的截止、周期账单的下一期，存的是"创建时所在时区的零点"这个绝对时刻，显示时却按设备当前的时区解释。设备换到时差更晚的地区（例如悉尼到上海、上海到伦敦），或两台设备时区不同时，全天任务会显示到前一天，逾期判断也会跟着提前。
  - **影响**：日期显示及按日判断仍可能不同；旧规则还可能因此算错下一期。2026-10-14 的固定时区修复覆盖新重复规则；旧规则等待参考时区确认，不自动迁移。数据不会因此丢失。
  - **暂不修复的原因**：彻底修复要把全天日期改成和时区无关的存法（类似 iCalendar 的 DATE 值和 Google 日历接口的 `date` 字段）。这涉及 41 个文件、约 110 处日期计算，需要迁移已有数据、升级同步格式，所有设备还得一起更新，风险高。
  - **以后可选的方案**：
    - 小方案：设置里加一个"固定时区"开关，类似苹果日历的"时区覆盖"，不需要迁移数据；
    - 完整方案：按上面的存法改，并做数据迁移。
  - **详细分析**：原详细分析报告当前未保留，以上为当时的分析摘要。
