# 发布准备 · iPhone / iPad / Mac · 2026-10-21

当前版本以 [CHANGELOG](../../CHANGELOG.md) 最新条目为准，当前数据格式见 [开发与验证](../../DEVELOPMENT.md#数据与维护约定)。以下为当前 Pro 发布准备；文末旧版本记录仅作历史参考。2026-10-22 已按授权发布中英文网站；应用仍仅作发布准备，不提交审核、上传构建、替换应用或操作真实数据。

## 网站与应用链接（2026-10-22 公开核验）

| 用途 | 地址 | 本次公开核验 |
| --- | --- | --- |
| 中文支持 | https://jackhuangzihao.github.io/xiaojitally-support/index.html | HTTP 200，已更新并核对发布文件 |
| 中文隐私 | https://jackhuangzihao.github.io/xiaojitally-support/privacy.html | HTTP 200，已更新 iCloud／内购说明 |
| 英文支持 | https://jackhuangzihao.github.io/xiaojitally-support/en/index.html | HTTP 200，已发布并核对文件 |
| 英文隐私 | https://jackhuangzihao.github.io/xiaojitally-support/en/privacy.html | HTTP 200，已发布并核对文件 |

应用的 `TallyPrivacyPolicyURL` 与 `TallyPrivacyPolicyEnglishURL` 使用上述隐私地址。App 会按自身语言选择对应页面；英文缺项时保留中文配置回退。包检查只验证配置，不代替公网访问与内容检查。网站四页于 2026-10-22 发布并通过公开访问核验，网站提交为 `a131eefcb19d863b6ba10053d00855766e2fb8f9`。**网站上线仍不能代替内购配置、正式签名与真机购买验收，不视为已正式开售**。

本地网站位于仓库旁 `Tally项目/网站/tally-github-pages/`，不是应用 Git 仓库的一部分。修改前另有独立 Git 备份。只发布这些静态网页和所需样式／图片，不向公开网站仓库推送应用源码、备份、测试日志、账号凭据或 `.storekit` 文件。

## App Store Connect 填写值

GitHub Pages 只托管网页。下面的三个真实商品要在 App Store Connect 配置；本轮已登录并只读核验，未创建商品或保存后台设置。应用与本地测试配置定义了预期的商品 ID，后台尚未创建。

### 后台实查结果（2026-10-21；2026-10-22 再查协议前置条件）

核对对象为 `TallyNest`（Apple ID `6817347328`，Bundle ID `local.jianshi.personal`）。iOS 和 macOS 的 1.0 版本在同一 App 记录下，均为“准备提交”。

| 项目 | 实查状态／下一步 |
| --- | --- |
| 买断内购 | 列表为空，显示“创建”；需创建非消耗型买断商品 |
| 月付／年付 | 尚无订阅组，显示“创建”；需创建订阅组及两个订阅 |
| 中文隐私网址 | 已填 GitHub Pages 中文地址；公开网站已于 2026-10-22 更新 |
| 英语（澳大利亚）隐私网址 | 显示“–”，尚未填写；英文网页现已上线，待后台补填 |
| 隐私问卷 | 当前声明“其他诊断数据／用于 App 功能／与用户身份关联”；需与最终收集行为逐项核对后更新，不能因代码隐私清单为空就直接照填“不收集” |
| 英语（澳大利亚）商店资料 | iOS 描述、关键词、支持网址、版权和审核联系资料为空；App 信息中的副标题仍为中文，需补英文 |
| 审核登录说明 | iOS“需要登录”已勾选但用户名／密码为空。当前 App 不要求小记账号，核对后应取消该勾选，并在备注解释可选 iCloud 及 Apple 内购 |
| 商务 | 表格仅有免费 App 协议“有效（新协议可用）”；页面要求先更新法律实体，再签付费 App 协议。未核验或修改银行／税务详情 |
| 开发者协议 | 页面提示许可协议更新，需账户持有人在开发者账户自行查阅并接受；本轮未代为接受 |
| 欧盟地区 | 交易商状态尚需完成；计划在欧盟销售时由账号持有人按实际身份完成验证 |

以上均为查看结果，不表示相关问题已在后台修复。Mac 版本的各语言产品页资料本轮未逐项核验，仍需填写及复查。英文副标题可参考 `Tasks, calendar & finances`，正式提交前由你确认名称与文案。

隐私问卷依据：[Apple 的数据收集定义与 Apple 服务说明](https://developer.apple.com/app-store/app-privacy-details/)。目前源码未发现第三方诊断上传 SDK，网络请求包含 ECB 汇率、私有 CloudKit 和 StoreKit。还需核对最终分发配置及你实际接收／使用的诊断数据；本轮不发布隐私回答。

### 商品填写值

| 项目 | 类型／期限 | 必须一致的商品 ID | 本地测试参考价（USD） |
| --- | --- | --- | --- |
| 月付 Pro | 自动续订订阅／1 个月 | `local.jianshi.personal.pro.monthly` | 2.99 |
| 年付 Pro | 自动续订订阅／1 年 | `local.jianshi.personal.pro.annual` | 19.99 |
| 买断 Pro | 非消耗型／一次购买 | `local.jianshi.personal.pro.lifetime` | 59.99 |

这些价格来自当前 `.storekit` 测试文件，**不表示商店已定价**；由你核对并选择正式价格档位与销售地区。应用显示 Apple 返回的当地价格。不要照抄 `.storekit` 内部 ID 或订阅组 ID，后台会生成自己的 ID。

1. 在“商务”检查付费 App 协议、税务、银行资料，确保协议有效。协议及银行税务信息由账号持有人自行确认和提交。
2. 打开正确的 App 记录，核对 iOS 与 macOS 是同一通用购买 App 的平台版本，两端使用相同的上述商品 ID；仅使用同一个 iCloud 账号不能代替此配置。
3. 在“订阅”中新建或核对 `Tally Pro` 订阅组。月付和年付提供相同权益，放在同组、同一服务级别（1）；分别选择 1 个月和 1 年。
4. 在“App 内购买项目”新建或核对买断，类型选择“非消耗型”。商品 ID 与类型创建后不能任意修改，已有同 ID 商品应复用并检查。
5. 为三个商品补齐英文和简体中文、价格、销售地区、审核截图与备注。确认所有必要字段已完成。审核截图应来自实际购买页，不用隔离测试控制页或含“Test price”的截图冒充正式展示。
6. 家人共享本地测试配置为关闭；如计划开启，先确认权益方案并补充共享／撤销验收。月付、年付和买断都通过同一 App Store 购买账号跨平台恢复；购买买断不会自动取消已有订阅。
7. 在应用资料填写支持／隐私网址，核对 App 隐私回答、分级、各语言描述和截图；网页上线后再核对每个链接。不要把代码里的隐私清单当成后台资料已经填写。
8. 首次内购随应用版本一起加入同一审核提交；本轮不执行提交。正式签名、Production CloudKit、匹配的 dSYM 和最终归档需要单独验收。

可用的商品本地化文案（名称最多 30 字符；以下简介均不超过内购项目的 45 字符限制）：

| 商品 | 英文名称 | 中文名称 |
| --- | --- | --- |
| 月付 | Tally Pro monthly | 小记 Pro 月付 |
| 年付 | Tally Pro annual | 小记 Pro 年付 |
| 买断 | Tally Pro lifetime | 小记 Pro 买断 |

- 英文简介：`Finance insights and expanded limits.`
- 中文简介：`进阶财务分析与更多管理空间，三端通用。`
- 订阅组显示名称可填英文 `Tally Pro`／中文 `小记 Pro`。
- 审核备注建议：Pro 的月付、年付和买断提供相同权益；入口在设置 → Pro；包含恢复购买和管理订阅；日／周／月排期、任务关联账单、iCloud 同步免费。任务／账单总量不限。超额现有项目在到期后保留并可编辑。

## 最终验收边界

本地 StoreKit、模拟器和合成数据检查不等于真实商店配置已完成。网站已发布；待后台配置完成后，再安排单独授权的两端 TestFlight／真机验收：三种购买、恢复、到期、失败重试、退款／撤销，以及手机购买后同一 App Store 购买账号在 Mac 恢复（反向也检查）。

真实 iCloud 双设备同步、Production 结构及 79 升级到 80 的真实账号验收仍需单独授权与可验证备份；同一云账号的设备应统一更新，不能让 79 继续读写新格式。此次不执行这些步骤。

参考：[Apple 内购配置概览](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/overview-for-configuring-in-app-purchases/)、[订阅级别](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/auto-renewable-subscription-information/)、[内购本地化字段](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information/)、[首次内购提交](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase)。

---

以下为历史版本说明，不能作为当前版本已完成发布验收的依据。

# 当前版本：0.2.0（36）· 2026-09-28

> 整理说明（2026-10-05）：本文保留原有说明。文中构建、源码、备份等相对路径以桌面“软件/简事”工程根目录为起点；当前版本与运行方式以根目录 README.md 为准。

新增 Mac 记账模块，与待办共用完整备份；周视图支持双击空白新建任务。详见 [记账使用说明](记账使用说明.md) 与 [本轮验收](../历史验收/记账版本验收.md)。应用仍使用原本的数据位置。以下保留此前版本说明。

---

# Mac 商店准备 · 2026-09-25

## 当前交付 · 0.1.29（32）

同一项目包含本地 Jianshi 与商店 Jianshi-AppStore 构建配置。商店配置启用沙盒、用户选择文件的读写权限，并禁用调试权限注入；两种配置包含隐私清单且不登记已停用的小组件动作。

/Applications/简事.app 更新为本地配置，以继续读取原有任务。无需安装第二份应用；本轮未把本地数据库切换到商店沙盒。

## 数据迁移方式

1. 在正在使用的版本中：设置 → 导出完整备份，保存 JSON。
2. 退出旧版，安装正式签名的商店版。
3. 商店版首次打开直接进入主界面。需要迁移时，在设置 → 从备份恢复，选择 JSON 并确认恢复方式。核对任务、清单与完成记录；完整迁移可选择替换，恢复前会保存副本。
4. 新用户直接开始添加任务，无需经过迁移欢迎页。

旧版数据库和旧备份不删除、不移动。商店版使用沙盒 Application Support/Jianshi/Tasks.store；不会直接打开旧试验版遗留在沙盒内的 Jianshi.store。旧版与商店版不会自动互通，迁移后应只使用正式版，避免分叉。

原因：本机确实存在两个年代不同的数据位置。系统的 container-migration.plist 面向首次创建容器，无法可靠处理已存在的旧容器，也不能判断哪一份最新。因此本轮采用明确的备份导入，不自动复制或覆盖 SQLite 文件。

迁移只使用现有 JSON 备份格式：包含所有任务、ID、日期与起止时间、截止、优先级、备注、子任务、重复规则、完成记录、最近删除、清单层级、颜色和 emoji。它不迁移界面偏好和旧版自动备份历史文件；这些旧文件仍留在原位置。过期提醒按原恢复逻辑标记待调整，系统通知权限需另行确认。

恢复前仍会生成副本并校验数据；失败沿用现有保存恢复保护。

## 本轮验证

- 本地、商店双架构编译通过，均通过 567 项自检；独立沙盒额外通过 9 项存储与迁移检查。
- 首次启动不再展示迁移页面。设置沿用已验证的导入导出流程。
- 提醒链接冷启动、编辑中延后、已删除任务提示已通过实际界面检查；系统通知横幅点击与最终分发签名仍需实机验收。
- 两种构建的资源内含隐私清单，不再包含小组件动作元数据。
- 数据库未切换，测试只使用独立容器中的模拟任务。

## 开发者复测

```sh
xcodebuild -project Jianshi.xcodeproj -scheme Jianshi-AppStore -configuration AppStore -destination 'platform=macOS' -derivedDataPath /private/tmp/jianshi-store-check CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

这是本地临时签名构建，不可直接提交商店。`--self-check` 运行通用自检；`--sandbox-check` 仅接受 `local.jianshi.sandboxcheck.` 开头且位于其对应容器的临时测试身份，以避免写入正式数据库。应复制构建、更换为唯一测试标识，再使用 JianshiStore.entitlements 重签测试副本后运行。每次检查使用新测试标识，不在已有测试数据库上重复创建夹具。测试扩展未安装到 Applications。

## 尚需会员与后续验收

- 使用已开通会员的团队设置 Bundle ID、商店分发签名及配置文件，Archive / Validate，验证最终签名的权限。
- 以最终商店签名重测导入导出、升级与重新安装；不得把临时签名测试等同于商店审核通过。
- 拖动、通知、文件选择、最低支持 macOS 与其他 Mac 的实机验收；原审查记录中的拖放异步取消风险仍待单独修复验证。
- iPhone 本轮不改发布配置；本轮未重新运行 iPhone 构建和真机验收。
- CloudKit 容器与两端合并/冲突/离线/满额测试。
- 付费协议、税务与银行资料；收费范围确定后再接入订阅、恢复购买、沙盒交易测试。
- 隐私政策、条款、支持页面与 App Store Connect 资料。

普通用户不需要操作上述构建步骤。会员开通之前可以继续使用现有应用；不要手工搬动 Library 中的数据库文件。
