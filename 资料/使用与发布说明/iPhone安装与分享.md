# 简事：自己在 iPhone 上用，以及给朋友试用

> 整理说明（2026-10-05）：本文保留原有说明。文中构建、源码、备份等相对路径以桌面“软件/简事”工程根目录为起点；当前版本与运行方式以根目录 README.md 为准。

## 当前手机版源码 · 0.2.11（build 47）

已同步 Mac 最新共享功能：完整待办、清单、提醒与重复任务、备份恢复，以及记账的账单、统计、账户资产、账本/分类管理、转账换汇、退款和任务关联。

手机底部以“待办 / 记账”切换；记账左上角菜单进入账单、统计、资产、管理、最近删除及设置与备份。记一笔、账户编辑、统计工具栏已适配手机宽度，分类按触屏排列，金额输入使用数字与符号键盘。

本次同步包含四项修复：夏令时日历坐标及改期、汇率估算来源提示、统计不完整时暂停涨跌比较、删除消费和退款按独立批次恢复。旧版没有删除批次的退款仍可单独恢复。

手机保留触屏操作；Mac 的鼠标边缘翻页和拖动拉伸不作为手机操作方式。手机可通过编辑任务设置起止日期与时间。

要求 iOS 17 或更新版本。iPhone 模拟器 Debug 与未签名真机 Release 构建通过；模拟器通过 808 项适用自检，其中 241 项记账检查。也检查了共享代码的 Mac 编译。模拟器验证了页面入口、记一笔和窄屏布局；没有在你本人的 iPhone 实机上验证触摸、通知或安装。

**目前不是可直接发送给朋友安装的 IPA / TestFlight 包。** 真机还需在 Xcode 中使用自己的开发团队签名并安装；本次检查时 iPhone 未连接。不要卸载原手机应用，以免删除本机数据。

项目已预留同步所需的数据结构适配和升级保护副本，详情见 [iCloud同步准备.md](iCloud同步准备.md)。尚未接通 CloudKit。

Mac 与 iPhone **功能共用、数据各自保存**，尚无 iCloud 自动同步。关闭应用或重启后，本地保存的数据仍在。可在设置中从 Mac 导出备份，经“文件”导入手机，支持追加或替换；替换会覆盖目标设备的现有内容，操作前先备份。备份不等于双向同步。

自动备份也在当前设备内。卸载应用、丢失手机或设备损坏可能同时失去数据库和本地备份；重要数据应额外手动导出到应用以外的安全位置。

## 自己的 iPhone：先免费安装测试

需要一根连接 Mac 与 iPhone 的数据线，以及自己的 Apple 账户。

1. 用 Xcode 打开此文件夹里的 **Jianshi.xcodeproj**。
2. 在 **Xcode → Settings → Accounts / Apple Accounts** 中登录自己的 Apple 账户。
3. 连接并解锁 iPhone，在手机上按提示选择“信任此电脑”。
4. 在 Xcode 的项目设置中选择 **Jianshi → Signing & Capabilities**，开启 **Automatically manage signing**，把 **Team** 设为自己的 **Personal Team**。
5. 在 Xcode 顶部选择 **Jianshi** 方案，运行设备选择自己的 iPhone。
6. 如果 Xcode 要求启用开发者模式，按引导在手机的 **设置 → 隐私与安全性 → 开发者模式** 开启，并完成重启确认。若该入口未出现，先完成 Xcode 与手机配对。
7. 点击 Xcode 左上角运行按钮（或按 ⌘R）。首次可能需要下载设备支持组件。安装成功后，在手机主屏幕打开“简事”。

如果提示应用标识已被占用，交给我调整手机端签名配置；不要随意更改 Mac 端标识，以免切换已有数据的访问位置。

免费个人签名有效期为 **7 天**，到期后需重新从 Xcode 构建安装。通常不需要先删除应用；请保留原应用及数据。普通 Apple 账户可以进行个人真机测试，无需先购买付费会员。

来源：[Apple 账户与免费测试限制](https://developer.apple.com/help/account/basics/about-your-developer-account)、[开启开发者模式](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)。

## 朋友的 iPhone：建议通过 TestFlight

这是准备邀请朋友长期试用时采用的路线，不需要先公开上架 App Store。

**你需要准备：**

- Apple Developer Program 付费会员：标准费用为每年 99 美元，实际当地价格以注册页面为准。
- App Store Connect 中的应用记录、可分发签名和上传构建。
- 提交外部测试所需的信息与测试审核；首个提交外部测试的构建需经过审核。

**朋友需要做：**

1. 在 iPhone 安装 Apple 的 **TestFlight**。
2. 打开你发出的测试邀请或测试链接。
3. 接受邀请，在 TestFlight 中点击安装“简事”。

朋友无需购买开发者会员，也无需把 Apple 账户密码交给你。每个测试构建最多可使用 **90 天**，需要定期发布更新。TestFlight 可以先服务小范围测试，等软件成熟后再考虑公开上架。

不能把当前的 Mac `.app` 或模拟器构建发送给朋友，就直接安装到他们的 iPhone；需要完成 iPhone 的签名与分发流程。

来源：[会员注册与费用](https://developer.apple.com/programs/enroll/)、[TestFlight 说明](https://developer.apple.com/testflight/)、[外部测试与审核](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/)、[测试版本期限](https://testflight.apple.com/)。

## 朋友的 Mac

Mac 仍使用现有分享包中的压缩版 **简事.app** 和使用说明，不需要发送源代码或你的任务数据。当前 Mac 分享包为 0.2.11；本次手机适配不需要朋友重新安装 Mac 版。正式对外分发前还应完成 Developer ID 签名和 Apple 公证。

来源：[Apple Developer ID 分发说明](https://developer.apple.com/developer-id/)。

## 文件说明

- **简事.app**：你现在使用的 Mac 应用。
- **Jianshi.xcodeproj、Sources、Assets.xcassets**：可继续开发、编译的完整原生工程。
- **设计原型**：前期界面参考，属于历史方案；实际功能以当前应用为准。
- **README.md**：当前使用方法、已完成范围和验证记录。
- **企划与迭代说明.md**：产品定位和后续计划。
- **build**：本机编译产物和缓存，不是给朋友分发的内容。

真实任务数据仍由系统的应用数据目录保存；移动本工程和应用不会主动移动、重置或清空任务。给朋友提供的是安装包或 TestFlight 邀请，不需要把你的工程或任务数据发给他们。
