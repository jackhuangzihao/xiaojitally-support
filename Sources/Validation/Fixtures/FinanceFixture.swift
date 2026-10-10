import Foundation
import SwiftData

extension FinanceChecks {
    #if (os(macOS) && JIANSHI_APP_STORE) || targetEnvironment(simulator)
    static func seedUI() throws {
        guard let id = Bundle.main.bundleIdentifier, id.hasPrefix("local.jianshi.sandboxcheck.finance") else { throw TaskBackup.invalid("UI fixture requires a disposable sandbox identity") }
        #if os(macOS)
        guard NSHomeDirectory().contains("/Containers/" + id + "/Data") else { throw TaskBackup.invalid("UI fixture requires a disposable Mac sandbox") }
        #else
        guard NSHomeDirectory().contains("/CoreSimulator/Devices/"), NSHomeDirectory().contains("/Containers/Data/Application/") else { throw TaskBackup.invalid("UI fixture requires a disposable iOS simulator sandbox") }
        #endif
        let container = try Store.make(), context = container.mainContext
        guard try FinanceStore.read(context) == nil, try context.fetch(FetchDescriptor<TaskItem>()).isEmpty else { throw TaskBackup.invalid("Fixture requires an empty store") }
        var ledger = FinanceData.initial
        let bank = MoneyAccount(name: "日常银行卡", opening: 10000, type: "debit", bankName: "招商银行"), aud = MoneyAccount(name: "commonwealth", currency: "AUD", opening: 4000, type: "debit", bankName: "Commonwealth Bank")
        let travel = MoneyBook(name: "澳洲旅行", defaultAccountID: bank.id)
        ledger.books[0].budget = 1000; ledger.books[0].emoji = "🏠"
        ledger.accounts = [bank, aud]; ledger.books.append(travel)
        var lunch = MoneyEntry(); lunch.title = "午餐"; lunch.notes = "和同事一起，AA 后自己付了一半"; lunch.amount = 50; lunch.accountAmount = 50; lunch.baseAmount = 50; lunch.accountID = bank.id; lunch.bookID = ledger.books[0].id; lunch.categoryID = ledger.categories[0].id
        var hotel = lunch; hotel.id = UUID(); hotel.title = "预订酒店"; hotel.amount = 800; hotel.accountAmount = 800; hotel.baseAmount = 800; hotel.bookID = travel.id; hotel.categoryID = ledger.categories[4].id
        var transfer = lunch; transfer.id = UUID(); transfer.title = "转入澳元账户"; transfer.kind = .transfer
        transfer.amount = 100; transfer.accountAmount = 100; transfer.baseAmount = 100; transfer.destinationID = aud.id; transfer.destinationAmount = 20; transfer.fee = 2; transfer.baseFee = 2; transfer.categoryID = nil
        var income = lunch; income.id = UUID(); income.title = "上月收入"; income.kind = .income; income.amount = 500; income.accountAmount = 500; income.baseAmount = 500
        income.date = Dates.calendar.date(byAdding: .month, value: -1, to: Date())!
        ledger.entries = [lunch, hotel, transfer, income]
        var foreignFee = transfer; foreignFee.id = UUID(); foreignFee.title = "验收：外币手续费"; foreignFee.currency = "AUD"
        foreignFee.accountID = aud.id; foreignFee.destinationID = bank.id; foreignFee.amount = 10; foreignFee.accountAmount = 10
        foreignFee.destinationAmount = 50; foreignFee.fee = 2; foreignFee.baseFee = 10; foreignFee.baseAmount = nil
        ledger.entries.append(foreignFee)

        let empty = MoneyAccount(name: "验收：空账户", opening: 10)
        ledger.accounts += [empty, MoneyAccount(name: "验收：已归档账户", opening: 30, archived: true)]
        ledger.books.append(MoneyBook(name: "验收：空账本", defaultAccountID: empty.id))
        ledger.categories.append(MoneyCategory(name: "验收：自建分类"))
        var fullRefund = lunch; fullRefund.id = UUID(); fullRefund.kind = .refund; fullRefund.title = "验收：全额退款"; fullRefund.refundOf = lunch.id
        ledger.entries.append(fullRefund)
        let secondAUD = MoneyAccount(name: "验收：第二澳元账户", currency: "AUD", opening: 1000)
        ledger.accounts.append(secondAUD)
        var historicalAUD = lunch; historicalAUD.id = UUID(); historicalAUD.title = "验收：历史澳元支出"
        historicalAUD.currency = "AUD"; historicalAUD.amount = 100; historicalAUD.accountAmount = 100
        historicalAUD.accountID = aud.id; historicalAUD.baseAmount = 500
        ledger.entries.append(historicalAUD)
        let usd = MoneyAccount(name: "美元账户", currency: "USD", opening: 500, type: "debit", bankName: "HSBC")
        ledger.accounts.append(usd)
        var sampleCoffee = lunch; sampleCoffee.id = UUID(); sampleCoffee.title = "示例 · 咖啡"; sampleCoffee.currency = "USD"
        sampleCoffee.date = MoneyEntry.timestamp(Date()); sampleCoffee.amount = 10; sampleCoffee.accountAmount = 10
        sampleCoffee.accountID = usd.id; sampleCoffee.baseAmount = nil
        var sampleIncome = sampleCoffee; sampleIncome.id = UUID(); sampleIncome.title = "示例 · 收入"; sampleIncome.kind = .income
        sampleIncome.amount = 120; sampleIncome.accountAmount = 120; sampleIncome.categoryID = nil
        var oldCoffee = sampleCoffee; oldCoffee.id = UUID(); oldCoffee.title = "验收：历史未折算支出"
        oldCoffee.date = Dates.calendar.date(byAdding: .month, value: -2, to: sampleCoffee.date)!
        ledger.entries += [sampleCoffee, sampleIncome, oldCoffee]
        let groceries = MoneyCategory(name: "超市买菜", symbol: "basket", income: false, parentID: ledger.categories[0].id)
        ledger.categories.append(groceries); ledger.entries[0].categoryID = groceries.id
        for i in ledger.entries.indices where ledger.entries[i].refundOf == lunch.id { ledger.entries[i].categoryID = groceries.id }
        ledger.books[0].defaultAccountID = usd.id
        try ledger.setManualRate(from: "USD", to: "CNY", text: "7.1")
        try ledger.mergeReferenceRates([MoneyRate(base: "AUD", quote: "CNY", rate: Decimal(string: "4.7")!, date: ExchangeRates.dayString(Date()))])
        UserDefaults.standard.set(false, forKey: "moneyAutoRates")
        let day = Dates.calendar.startOfDay(for: Date())
        let task = TaskItem(title: "验收：已有任务", scheduledAt: day.addingTimeInterval(15 * 3600)); task.hasTime = true; task.endAt = day.addingTimeInterval(16 * 3600)
        context.insert(task)
        let tomorrow = Dates.calendar.date(byAdding: .day, value: 1, to: day)!
        let plannedTask = TaskItem(title: "验收：明日待入账任务", scheduledAt: tomorrow.addingTimeInterval(12 * 3600)); plannedTask.hasTime = true
        context.insert(plannedTask)
        var due = lunch; due.id = UUID(); due.title = "验收：待入账支出 24"; due.pending = true
        due.date = day; due.amount = 24; due.accountAmount = 24; due.baseAmount = 24; due.taskID = task.id
        var future = due; future.id = UUID(); future.title = "验收：明日待入账收入 36"; future.kind = .income
        future.date = tomorrow; future.amount = 36; future.accountAmount = 36; future.baseAmount = 36
        future.categoryID = ledger.categories.first { $0.isIncome }!.id; future.taskID = plannedTask.id
        ledger.entries += [due, future]
        // Recurring bills: rent whose next occurrence was missed last month, a bill due today, and one coming up.
        var rent = lunch; rent.id = UUID(); rent.title = "验收：房租"; rent.amount = 3200; rent.accountAmount = 3200; rent.baseAmount = 3200
        rent.categoryID = ledger.categories[3].id; rent.date = Dates.calendar.date(byAdding: .month, value: -1, to: day.addingTimeInterval(9 * 3600))!
        try ledger.addRecurring(MoneyRecurring(repeating: rent, rule: "monthly", until: nil, in: ledger))
        var gym = lunch; gym.id = UUID(); gym.title = "验收：健身课"; gym.amount = 80; gym.accountAmount = 80; gym.baseAmount = 80; gym.date = day.addingTimeInterval(19 * 3600)
        try ledger.addRecurring(MoneyRecurring(repeating: gym, rule: "weekly", until: nil, in: ledger))
        var video = lunch; video.id = UUID(); video.title = "验收：视频会员（每 2 周）"; video.amount = 198; video.accountAmount = 198; video.baseAmount = 198
        video.date = Dates.calendar.date(byAdding: .day, value: 6, to: day)!
        try ledger.addRecurring(MoneyRecurring(repeating: video, rule: RepeatRule(interval: 2, unit: .week).text, until: nil, in: ledger))
        try FinanceStore.stage(ledger, in: context)
        let thursday = Dates.calendar.date(byAdding: .day, value: 3, to: Dates.calendar.dateInterval(of: .weekOfYear, for: Date())!.start)!
        let repeated = TaskItem(title: "验收：每日重复", scheduledAt: thursday.addingTimeInterval(13.5 * 3600))
        repeated.hasTime = true; repeated.endAt = thursday.addingTimeInterval(17.5 * 3600); repeated.isDone = true; repeated.completedAt = Date(); repeated.repeatRule = "daily"
        let stale = TaskItem(title: "验收：旧的独立记录", scheduledAt: Dates.calendar.date(byAdding: .day, value: -15, to: thursday)!)
        repeated.nextOccurrenceID = stale.id; context.insert(repeated); context.insert(stale)
        try Store.save(context)
        print("UI fixture created in disposable sandbox")
    }
    #endif

}
