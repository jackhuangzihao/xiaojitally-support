import Foundation
import SwiftData

extension SelfCheck {
    #if (os(macOS) && JIANSHI_APP_STORE) || targetEnvironment(simulator)
    /// UI examples are allowed only inside a disposable, empty test container.
    static func seedDayTimelineUI() throws {
        guard let id = Bundle.main.bundleIdentifier, id.hasPrefix("local.jianshi.sandboxcheck.day") else {
            throw TaskBackup.invalid("Day fixture requires a disposable sandbox identity")
        }
        #if os(macOS)
        guard NSHomeDirectory().contains("/Containers/" + id + "/Data") else {
            throw TaskBackup.invalid("Day fixture requires a disposable Mac sandbox")
        }
        #else
        guard NSHomeDirectory().contains("/CoreSimulator/Devices/"), NSHomeDirectory().contains("/Containers/Data/Application/") else {
            throw TaskBackup.invalid("Day fixture requires a disposable iOS simulator sandbox")
        }
        #endif
        let container = try Store.make(), context = container.mainContext
        guard container.configurations.allSatisfy({ $0.url.path.hasPrefix(NSHomeDirectory() + "/") }),
              try context.fetch(FetchDescriptor<TaskItem>()).isEmpty,
              try context.fetch(FetchDescriptor<TaskList>()).isEmpty,
              try context.fetch(FetchDescriptor<CalendarWeekTitle>()).isEmpty,
              try context.fetch(FetchDescriptor<CloudSyncState>()).isEmpty,
              try FinanceStore.read(context) == nil else {
            throw TaskBackup.invalid("Day fixture requires an empty store inside its own sandbox")
        }
        let today = Dates.calendar.startOfDay(for: Date())
        func time(_ minute: Int, offset: Int = 0) -> Date {
            Dates.clockTime(on: Dates.calendar.date(byAdding: .day, value: offset, to: today)!, minute: minute)
        }
        let life = TaskList(name: "生活"), study = TaskList(name: "学习"), work = TaskList(name: "工作")
        life.colorHex = "549981"; study.colorHex = "548FA8"; work.colorHex = "9C8464"
        for (index, list) in [life, study, work].enumerated() { list.sortOrder = Double(index); context.insert(list) }
        let lunch = TaskItem(title: "午餐与整理房间", scheduledAt: time(705), list: life)
        lunch.hasTime = true; lunch.endAt = time(765); lunch.notes = "先吃午餐，再简单整理一下书桌。"
        lunch.subtasks = [Subtask(title: "整理书桌")]
        let game = TaskItem(title: "我要打游戏", scheduledAt: time(825), list: study)
        game.hasTime = true; game.endAt = time(1170); game.priority = 2
        game.notes = "记得叫上队友，提前约好时间。"
        game.subtasks = [Subtask(title: "Apex"), Subtask(title: "王者荣耀"), Subtask(title: "炉石传说")]
        if CommandLine.arguments.contains("--large-day-details") {
            game.notes = String(repeating: "长备注展开检查：内容换行后仍然完整显示，收起后不能遮挡下一条任务。\n", count: 120)
            game.subtasks = (1...100).map { Subtask(title: "步骤 \($0)：检查长标题换行与完成状态是否正确") }
        }
        game.dueAt = time(0, offset: 8)
        game.reminderAt = Date().addingTimeInterval(-3600); game.reminderKind = "custom"; game.reminderNeedsAttention = true
        let pending = TaskItem(title: "整理下周计划", scheduledAt: today, list: work)
        let done = TaskItem(title: "回复邮件", scheduledAt: time(540), list: work)
        done.hasTime = true; done.endAt = time(555); done.isDone = true; done.completedAt = Date()
        let earlier = TaskItem(title: "读完这一章", scheduledAt: time(0, offset: -1), list: study)
        let overnight = TaskItem(title: "跨日安排", scheduledAt: time(1410, offset: 1), list: work)
        overnight.hasTime = true; overnight.endAt = time(75, offset: 2)
        let earlierTwo = TaskItem(title: "整理旧笔记", scheduledAt: time(0, offset: -2), list: study)
        let earlierThree = TaskItem(title: "检查出行安排", scheduledAt: time(0, offset: -3), list: life)
        let earlierFour = TaskItem(title: "回复上周的邮件", scheduledAt: time(0, offset: -4), list: work)
        for task in [lunch, game, pending, done, earlier, overnight, earlierTwo, earlierThree, earlierFour] { context.insert(task) }
        try Store.save(context)
        UserDefaults.standard.set("zh", forKey: "appLanguage")
        UserDefaults.standard.set("list", forKey: "planningView")
        UserDefaults.standard.set(false, forKey: "showDayFreeTime")
        print("DAY UI fixture created in disposable sandbox: \(id)")
    }
    #endif

}
