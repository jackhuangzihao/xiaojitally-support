# 小记 Tally · iCloud 同步 · 1.0（53）

## 53 版兼容性

新增周标题、账户银行和两级分类；这些内容随个人同步和完整备份一起保存。同步/备份格式已升级为 7，仍可导入旧格式；旧 52 版遇到新格式会停止同步并提示升级，避免删除不认识的新字段。测试时 Mac 和 iPhone 都应更新到 53 或后续兼容版本。

首次打开新结构前另存 `SchemaBackups/*.before-feedback-v2.sqlite`。手动汇率不会被另一端的自动参考价静默覆盖；冲突仍需选择。没有新增 CloudKit 记录类型或字段，无需为本次变化重新部署生产结构。

## 使用范围

仅同一 Apple 账户的个人设备同步。任务（含备注、子任务、重复和删除状态）、周标题、清单、账户（含银行）、账本、分类（含父子层级）、账单与汇率同步；不包含多人协作、共享清单、通知授权、语言和外观偏好、本机备份文件。

在两端设置中开启 iCloud。默认关闭，开启前说明上传至个人 iCloud 私有数据库并占用个人空间。应用在前台打开时每 30 秒检查远端，保存后合并短时间内的修改再上传。未变化时只读取版本摘要，不下载整个账本。Apple 返回等待时间时遵守该时间后重试。关闭或长时间挂起应用不保证继续同步，下次打开再同步。

离线可以继续编辑。网络错误、空间不足、未登录与云端错误不会把本地数据库锁成只读。设置可看同步状态、上次完成时间和手动重试。切换 Apple 账户会暂停，必须回到原账户，不能把旧账户的数据无提示地上传到新账户。

## 数据保护

- 保留原来的 SwiftData 本地数据库、记录编号和完整 JSON 备份格式；新增一条只保存在本机的同步状态，不将设备账户绑定和合并基线写入普通备份。
- 首次打开新结构前保存一致性 SQLite 升级副本：数据库旁 `SchemaBackups/*.before-cloud-sync-v1.sqlite`。不以空库替代失败的数据库。
- 以“上次已同步内容”为基线，逐个普通任务、清单、账户、账本、分类和账单做三方合并。重复任务依据前后记录连接作为整条序列合并，防止跨日期离线完成后留下两条序列。两台设备新增不同账单可以合并；同一项或同一重复序列双方都有修改、删除与编辑冲突时暂停，请用户选择。冲突窗口列出所有冲突项目、任务状态和差异字段；选择适用于本次所有冲突。
- 账目使用一个 CloudKit 私有快照记录原子提交，转出和转入不会被拆开。使用服务器版本校验，其他设备刚写入时拒绝旧版本覆盖并在后续重试。
- 重新检查合并后所有关联和金额约束。删除账户与另一端新增账单、退款与原支出不一致等不能安全合并时，不更新任一端。可导出双方副本核对，不能静默丢弃一端数据。
- 本位币不同并伴随双方修改时，冲突选择涉及整本账目，不能拼接不同本位币的已锁定金额。
- 合并前双方副本保存在 `JianshiBackups/BeforeSync`，复用现有按小时/天保留的自动备份规则；设置中可导出最近副本。普通自动备份仍独立运行。
- 应用正在编辑的表单关闭前不导入远端内容。JSON 编解码、快照合并、摘要和上传文件写入在后台执行；模型读取和事务写回留在主线程。上传等待期间新发生的本地修改会再次合并。后台结果写回前检查本地保存版本和未保存编辑，过期结果放弃写回并安排重试，不覆盖新修改。
- 同一重复任务、同一下一次日期使用稳定编号；不同日期产生的分支与整个重复序列一起选择，保留所选一端的后续任务和历史，未选分支留在恢复副本中。新设备首次连接已有云端时，未修改且未被任务/子清单使用的默认清单采用云端状态，不恢复云端已删的默认项。空白初始账本也按此原则处理。首次创建云端副本仍保留本机默认项。旧设备不同编号的同名项目不自动删除。
- 从备份替换/删除的数据会继续同步到其他设备，恢复确认框已说明这一点。同步不是独立备份。

当前每份同步快照上限 50 MB；超过时保持本地数据并明确提示。大型账本实际出现性能瓶颈后，再迁移为逐记录增量传输。没有添加第三方后端、账号系统或依赖库。

## Apple 配置

- 团队：JY659LHUCS；Bundle ID：`local.jianshi.personal`。
- 容器：`iCloud.local.jianshi.personal`，仅使用 privateCloudDatabase。
- Mac / iPhone 都已配置 iCloud + CloudKit entitlement。开发签名显式使用 Development；通过 Xcode/App Store Connect 分发时必须由导出签名使用 Production。
- 数据库维持 `cloudKitDatabase: .none` 是有意的：同步由 CloudKit 服务执行，避免 SwiftData 把整本 FinanceLedger 独立同步而覆盖双方账目。
- Development 中需要的记录类型为 `TallySnapshot`，字段 `snapshot: Asset`、`formatVersion: Int(64)`、`digest: String`，使用默认 zone。通过记录 ID 读取，不需要查询索引。
- 2026-09-30 已经用户确认，将 TallySnapshot 及三个字段部署到 Production，并在生产界面核对字段类型。只发布结构，没有迁移或删除记录。以后新增字段仍须核对并部署；不要 Reset Environment。
- 旧版本 1.0（49/50）没有这项功能，必须分别上传 Mac 和 iOS 的新构建。

## 验收

53 版：Mac AppStore 配置 arm64/x86_64、iPhone 设备与模拟器编译通过；1046 项自检通过，其中同步检查 79 项、财务检查 285 项；另有 9 项隔离存储检查通过。5000 条任务和 5000 条账目的性能检查，以及默认币种/历史换算保留检查通过。Mac 和 iPhone 构建通过隐私清单、加密声明和停用组件检查。本轮没有执行真实 CloudKit 双机读写，也没有上传 53 版。

52 版历史验证：969 项自检通过，其中同步检查 63 项、财务检查 241 项；两端 dSYM UUID 匹配。新增回归覆盖跨日离线完成、双方冲突选择、后续分支与完成历史、重试幂等、默认清单改名/语言/删除/已使用保护、同步期间已保存和未保存编辑的写回拦截。

后续分发验收：2026-09-30 两端 1.0（52）已签名归档并成功上传 App Store Connect，TestFlight 中两端均为“准备提交”状态，尚未添加测试员。上传前移除了不支持的 icloud-container-development-container-identifiers 权限；保留正确的容器权限，由导出配置选择 Production。没有执行新的双机云端读写或 UI 真机验收。

真实 CloudKit 读写与生产部署结果另见本次验收记录；本机编译和模拟合并不能证明真机互通。iPhone 暂不能连接，因此尚未执行 Mac↔iPhone 双机验收，不应据此直接宣称同步已可正式发布。

双机验收：两端同一 iCloud 账号、同一云环境，分别新增/修改/完成/删除任务和新增转账；断网各自修改后重新联网；同一账单两端冲突；设置中确认上次完成时间和余额，重启后复核。先使用测试记录并导出各端备份。

参考：
- https://developer.apple.com/documentation/cloudkit/ckdatabase/modifyrecords(saving:deleting:savepolicy:atomically:)
- https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema

## 安装与发布记录

源码已准备为 1.0（53），Mac 和 iPhone 共用本次改动，本轮未替换已安装应用。2026-09-30 的历史安装记录为本地非沙盒 0.2.12（48）；52 版已上传，53 版尚未上传。AppStore 配置使用沙盒，不能直接把它覆盖旧本地版并假定能自动读取旧路径；迁移请先在旧版本导出完整备份，再在商店/TestFlight版本导入。

GitHub Pages 的同步版支持/隐私文案在“同步版网站文案-待发布”中，尚未发布；发布同步版前需要同步更新网站。

加密声明：两端 Info.plist 已添加 `ITSAppUsesNonExemptEncryption = false`。当前使用 Apple 提供的 CloudKit/HTTPS 和系统 SHA256，没有非豁免自实现加密。参考 [Apple 的键值说明](https://developer.apple.com/documentation/BundleResources/Information-Property-List/ITSAppUsesNonExemptEncryption) 与 [文稿要求](https://developer.apple.com/help/app-store-connect/reference/export-compliance-documentation-for-encryption/)。
