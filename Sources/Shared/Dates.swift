import Foundation

enum UISettings {
    static func resolvedLanguage(_ preference: String?, preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        if preference == "zh" || preference == "en" { return preference! }
        for language in preferredLanguages {
            let code = language.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first
            if code == "zh" { return "zh" }
            if code == "en" { return "en" }
        }
        return "en"
    }
    static var language: String { resolvedLanguage(UserDefaults.standard.string(forKey: "appLanguage")) }
    static var locale: Locale { locale(for: UserDefaults.standard.string(forKey: "appLanguage")) }
    static func locale(for preference: String?, preferredLanguages: [String] = Locale.preferredLanguages) -> Locale {
        Locale(identifier: resolvedLanguage(preference, preferredLanguages: preferredLanguages) == "en" ? "en_US" : "zh_CN")
    }

    static func backupFailure(_ stored: String, language: String? = nil) -> String {
        guard !stored.isEmpty else { return "" }
        var detail = stored
        for prefix in ["自动备份未完成：", "Automatic backup failed: "] where detail.hasPrefix(prefix) {
            detail.removeFirst(prefix.count)
        }
        return L("自动备份未完成：", "Automatic backup failed: ", language: language) + detail
    }
}

func L(_ chinese: String, _ english: String, language: String? = nil) -> String {
    UISettings.resolvedLanguage(language ?? UISettings.language) == "en" ? english : chinese
}

enum Dates {
    /// Calendar canvases use wall-clock minutes, not elapsed time since midnight (DST days are 23/25 hours).
    static func clockMinute(_ date: Date, calendar: Calendar = Dates.calendar) -> Double {
        let p = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double((p.hour ?? 0) * 60 + (p.minute ?? 0)) + Double(p.second ?? 0) / 60
    }
    static func clockTime(on day: Date, minute: Int, reference: Date? = nil, calendar: Calendar = Dates.calendar) -> Date {
        // Continuation drags can start on an earlier day; shift calendar days before resolving DST hours.
        let remainder = minute % 1440
        let dayOffset = minute / 1440 - (remainder < 0 ? 1 : 0)
        let m = remainder < 0 ? remainder + 1440 : remainder
        let shiftedDay = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: day))!
        let start = calendar.startOfDay(for: shiftedDay)
        func resolve(_ policy: Calendar.RepeatedTimePolicy) -> Date {
            calendar.nextDate(after: start.addingTimeInterval(-1), matching: DateComponents(hour: m / 60, minute: m % 60, second: 0),
                              matchingPolicy: .nextTimePreservingSmallerComponents, repeatedTimePolicy: policy)!
        }
        let first = resolve(.first)
        // Keep the existing occurrence of an ambiguous autumn hour when editing that same day.
        if let reference, calendar.isDate(reference, inSameDayAs: start) {
            let last = resolve(.last)
            if calendar.timeZone.secondsFromGMT(for: last) == calendar.timeZone.secondsFromGMT(for: reference) { return last }
        }
        return first
    }
    static func clockSpan(from start: Date, to end: Date, on day: Date, calendar: Calendar = Dates.calendar) -> (start: Double, end: Double) {
        let midnight = calendar.startOfDay(for: day), next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))!
        let lower = max(start, midnight), upper = min(end, next)
        let a = lower <= midnight ? 0 : clockMinute(lower, calendar: calendar)
        let b = upper >= next ? 1440 : clockMinute(upper, calendar: calendar)
        // A repeated hour can end at an earlier clock reading. Keep that interval visible, never negative.
        return (a, b > a ? b : min(1440, a + max(0, upper.timeIntervalSince(lower) / 60)))
    }

    static func changingEndClock(_ value: Date, start: Date, end: Date) -> Date {
        var candidate = replacingDay(of: value, with: end)
        if candidate <= start {
            candidate = replacingDay(of: value, with: start)
            if candidate <= start { candidate = calendar.date(byAdding: .day, value: 1, to: candidate)! }
        }
        return candidate
    }

    /// The next time a repeating task comes back after `now`, or nil once that would be past `until` (a whole day).
    /// Missed occurrences are skipped rather than piled up.
    static func nextRepeat(_ base: Date, rule text: String, anchorDay: Int, after now: Date, until: Date? = nil) -> Date? {
        guard let rule = RepeatRule(text), let next = nextOccurrence(base, rule: rule, anchorDay: anchorDay, after: now) else { return nil }
        if let until, calendar.startOfDay(for: next) > calendar.startOfDay(for: until) { return nil }
        return next
    }

    private static func nextOccurrence(_ base: Date, rule: RepeatRule, anchorDay: Int, after now: Date) -> Date? {
        let cal = calendar, n = rule.interval
        switch rule.unit {
        case .day, .week:
            if rule.unit == .week, !rule.weekdays.isEmpty {
                // Chosen weekdays, in every n-th week counted from the task's own week.
                guard let baseWeek = cal.dateInterval(of: .weekOfYear, for: base)?.start else { return nil }
                var day = cal.startOfDay(for: max(base, now))
                for _ in 0..<(7 * n + 14) {
                    if let week = cal.dateInterval(of: .weekOfYear, for: day)?.start {
                        let weeks = (cal.dateComponents([.day], from: baseWeek, to: week).day ?? 0) / 7
                        let candidate = replacingDay(of: base, with: day)
                        if weeks >= 0, weeks % n == 0, rule.weekdays.contains(cal.component(.weekday, from: day)), candidate > now, candidate > base {
                            return candidate
                        }
                    }
                    guard let following = cal.date(byAdding: .day, value: 1, to: day) else { return nil }
                    day = following
                }
                return nil
            }
            let step = rule.unit == .day ? n : 7 * n
            let elapsed = max(0, cal.dateComponents([.day], from: cal.startOfDay(for: base), to: cal.startOfDay(for: now)).day ?? 0)
            let steps = max(1, elapsed / step)
            guard let candidate = cal.date(byAdding: .day, value: steps * step, to: base) else { return nil }
            return candidate > now ? candidate : cal.date(byAdding: .day, value: step, to: candidate)
        case .month:
            let months = max(n, (cal.dateComponents([.month], from: monthStart(base), to: monthStart(now)).month ?? n) / n * n)
            func candidate(_ offset: Int) -> Date? {
                let month = shiftMonth(base, by: offset)
                let last = cal.range(of: .day, in: .month, for: month)!.count
                var parts = cal.dateComponents([.year, .month], from: month)
                parts.day = min(max(1, anchorDay > 0 ? anchorDay : cal.component(.day, from: base)), last)
                parts.hour = cal.component(.hour, from: base); parts.minute = cal.component(.minute, from: base)
                return cal.date(from: parts)
            }
            guard let date = candidate(months) else { return nil }
            return date > now ? date : candidate(months + n)
        case .year:
            let years = max(n, (cal.dateComponents([.year], from: base, to: now).year ?? n) / n * n)
            func candidate(_ offset: Int) -> Date? {
                guard let year = cal.date(byAdding: .year, value: offset, to: base),
                      let days = cal.range(of: .day, in: .month, for: year) else { return nil }
                var parts = cal.dateComponents([.year, .month, .hour, .minute, .second], from: year)
                parts.day = min(max(1, anchorDay > 0 ? anchorDay : cal.component(.day, from: base)), days.count)
                return cal.date(from: parts)
            }
            guard let date = candidate(years) else { return nil }
            return date > now ? date : candidate(years + n)
        }
    }

    /// "3 小时 30 分" / "45 分钟"
    static func durationLabel(minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return L("\(rest) 分钟", "\(rest) min") }
        if rest == 0 { return L("\(hours) 小时", "\(hours) h") }
        return L("\(hours) 小时 \(rest) 分", "\(hours) h \(rest) min")
    }

    static func repeatLabel(_ rule: String) -> String {
        RepeatRule(rule)?.label ?? L("不重复", "Never")
    }

    /// A deadline may not come before the scheduled moment. Without times, whole days are compared.
    static func deadlineAllowed(due: Date, dueTimed: Bool, scheduled: Date?, scheduledTimed: Bool) -> Bool {
        guard let scheduled else { return true }
        if dueTimed && scheduledTimed { return due >= scheduled }
        return calendar.startOfDay(for: due) >= calendar.startOfDay(for: scheduled)
    }

    static func selectionAfterDayChange(_ selected: Date, previousToday: Date, now: Date) -> Date {
        sameDay(selected, previousToday) ? now : selected
    }

    static func groupLabel(_ date: Date, today: Date) -> String {
        if date == .distantFuture { return L("无日期", "No date") }
        if sameDay(date, today) { return L("今天", "Today") }
        return label(date, pattern: calendar.isDate(date, equalTo: today, toGranularity: .year) ? "M月d日" : "yyyy年M月d日")
    }

    static func monthName(_ month: Int) -> String {
        let formatter = DateFormatter(); formatter.locale = UISettings.locale
        return formatter.monthSymbols[month - 1]
    }
    static var weekdays: [String] {
        UISettings.language == "en" ? ["M", "T", "W", "T", "F", "S", "S"] : ["一", "二", "三", "四", "五", "六", "日"]
    }
    static func formatPattern(_ pattern: String, language: String) -> String {
        guard language == "en" else { return pattern }
        return ["M月d日 EEEE": "MMM d, EEEE", "yyyy年M月": "MMMM yyyy", "M月安排": "MMMM", "yyyy年M月d日": "MMM d, yyyy", "M月d日 E": "MMM d, E", "M月d日": "MMM d", "M月d日 HH:mm": "MMM d, HH:mm", "M月d日 E HH:mm": "MMM d, E HH:mm", "d日": "d", "yyyy年": "yyyy"][pattern] ?? pattern
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = UISettings.locale
        calendar.firstWeekday = 2
        return calendar
    }

    static func monthStart(_ date: Date) -> Date {
        calendar.dateInterval(of: .month, for: date)!.start
    }

    static func monthCells(_ date: Date) -> [Date] {
        let start = monthStart(date)
        let offset = (calendar.component(.weekday, from: start) + 5) % 7
        let days = calendar.range(of: .day, in: .month, for: date)!.count
        let count = ((offset + days + 6) / 7) * 7
        return (0..<count).map { calendar.date(byAdding: .day, value: $0 - offset, to: start)! }
    }

    static func shiftMonth(_ date: Date, by amount: Int) -> Date {
        calendar.date(byAdding: .month, value: amount, to: monthStart(date))!
    }

    static func weekCells(_ date: Date) -> [Date] {
        let offset = (calendar.component(.weekday, from: date) + 5) % 7
        let start = calendar.startOfDay(for: date)
        return (0..<7).map { calendar.date(byAdding: .day, value: $0 - offset, to: start)! }
    }

    static func replacingDay(of date: Date, with day: Date) -> Date {
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        let time = calendar.dateComponents([.hour, .minute], from: date)
        parts.hour = time.hour; parts.minute = time.minute
        return calendar.date(from: parts) ?? day
    }

    static func sameDay(_ a: Date, _ b: Date) -> Bool { calendar.isDate(a, inSameDayAs: b) }

    static func label(_ date: Date, pattern: String = "M月d日 EEEE") -> String {
        let cal = calendar, locale = UISettings.locale
        let format = formatPattern(pattern, language: UISettings.language)
        let key = locale.identifier + "|" + cal.timeZone.identifier + "|" + format
        // Native formatters are expensive to create on every calendar card. Keep a small per-thread cache.
        let storage = Thread.current.threadDictionary
        var cache = storage["Tally.dateFormatters"] as? [String: DateFormatter] ?? [:]
        if let formatter = cache[key] { return formatter.string(from: date) }
        let formatter = DateFormatter()
        formatter.calendar = cal; formatter.locale = locale; formatter.dateFormat = format
        if cache.count >= 32 { cache.removeAll() }
        cache[key] = formatter; storage["Tally.dateFormatters"] = cache
        return formatter.string(from: date)
    }

    static func matches(_ date: Date?, selected: Date, wholeMonth: Bool) -> Bool {
        guard let date else { return false }
        return wholeMonth ? calendar.isDate(date, equalTo: selected, toGranularity: .month) : sameDay(date, selected)
    }
}
