import SwiftUI

struct ProView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language = "system"
    var store = PurchaseStore.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Tally Pro").font(.largeTitle.bold())
                    Text(L("进阶财务分析，和更多管理空间。", "Explore financial trends and organise more."))
                    status
                    VStack(alignment: .leading, spacing: 12) {
                        Label(L("跨期趋势、统计日历、分类历史分析", "Trends across periods, statistics calendar and category history"), systemImage: "chart.xyaxis.line")
                        Label(L("清单、账户、账本、周期账单和预算不受免费额度限制", "Lists, accounts, books, recurring bills and budgets beyond the free limits"), systemImage: "square.stack")
                        Label(L("一次购买，iPhone、iPad 和 Mac 通用", "One purchase for iPhone, iPad and Mac"), systemImage: "laptopcomputer.and.iphone")
                    }.font(.callout)
                    if !store.developerUnlocked && !store.lifetime {
                        ForEach(store.offers) { offer in
                            Button { Task { await store.buy(offer.product) } } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(offer.product.title).font(.headline)
                                        Text(offer.product.billing).font(.caption)
                                    }
                                    Spacer()
                                    Text(offer.price).font(.title3.weight(.semibold))
                                }.frame(maxWidth: .infinity, minHeight: 44).padding(12)
                                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                                .disabled(store.busy || store.pendingProduct != nil || PurchaseCatalog.privacyURL == nil || store.grants.contains { $0.product == offer.product && $0.active })
                        }
                        if store.loadingOffers { ProgressView() }
                        if let error = store.offerError {
                            Text(error).foregroundStyle(.secondary)
                            Button(L("重新加载商品", "Reload products")) { Task { await store.loadOffers() } }
                        }
                        if PurchaseCatalog.privacyURL == nil {
                            Text(L("购买暂未开放，已有购买仍可恢复。", "Purchases are not yet available. Existing purchases can still be restored."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let message = store.message { Text(message).font(.callout).accessibilityIdentifier("purchase-result") }
                    if let error = store.verificationError {
                        Text(error).font(.callout).foregroundStyle(.secondary)
                        Button(L("重新验证", "Retry verification")) { Task { await store.refresh() } }
                    }
                    if !store.developerUnlocked {
                        Button(L("恢复购买", "Restore purchases")) { Task { await store.restore() } }
                            .disabled(store.busy).frame(minHeight: 44).accessibilityIdentifier("restore-purchases")
                        Link(L("管理订阅", "Manage subscriptions"), destination: PurchaseCatalog.subscriptionsURL)
                        if store.busy { ProgressView(L("正在处理…", "Processing…")) }
                    }
                    Text(L("订阅到期后，现有任务、账单和超出免费额度的项目仍可查看、修改、导出。只限制继续新增超额项目，并停用 Pro 分析。", "After expiry, existing tasks, entries and items beyond the free limits remain available to view, edit and export. Only further over-limit creation and Pro analysis are restricted."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L("月付与年付会自动续订，可在 Apple 账户中管理或取消。购买买断不会自动取消已有订阅，请自行管理，避免继续续费。", "Monthly and annual subscriptions renew automatically and can be managed or cancelled in your Apple account. Buying lifetime does not automatically cancel an existing subscription; manage it to avoid further renewal charges."))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if let url = PurchaseCatalog.privacyURL { Link(L("隐私政策", "Privacy policy"), destination: url) }
                        Link(L("使用条款", "Terms of use"), destination: PurchaseCatalog.termsURL)
                    }.font(.caption)
                }.padding(24)
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("完成", "Done")) { dismiss() } } }
        }
        .task { store.start(); await store.refresh(); await store.loadOffers() }
        #if os(macOS)
        .frame(width: 560, height: 700)
        #endif
    }
    @ViewBuilder private var status: some View {
        if store.developerUnlocked { Label(L("开发者版本 · Pro 已解锁", "Developer build · Pro unlocked"), systemImage: "checkmark.seal") }
        else if store.lifetime { Label(L("已购买永久 Pro", "Lifetime Pro purchased"), systemImage: "checkmark.seal") }
        else if store.isPro, let expiry = store.expiry {
            Label(L("Pro 有效至 ", "Pro active until ") + expiry.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(UISettings.locale)), systemImage: "checkmark.seal")
        } else if store.accessUnavailable { Text(L("暂时无法确认购买状态", "Purchase status could not be confirmed")) }
        else if !store.accessConfirmed { Text(L("正在验证购买状态…", "Verifying purchases…")) }
        else { Text(L("当前为免费版", "Free plan")) }
    }
}

struct ProUpgradeButton: View {
    var title = L("了解 Pro", "Explore Pro")
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: { Label(title, systemImage: "sparkles").frame(minHeight: 44) }
            .buttonStyle(.borderless)
            .sheet(isPresented: $showing) { ProView() }
    }
}

/// The preview is informative; the business operation checks the fresh count again before saving.
struct ProQuotaNotice: View {
    let quota: ProQuota
    let count: Int
    /// Shown once the limit is reached, e.g. which books already use the budget slot.
    var detail: String? = nil
    var body: some View {
        // Before this launch verifies the plan, a free-plan count would be a guess.
        if PurchaseStore.shared.accessConfirmed && !PurchaseStore.shared.isPro {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("\(quota.label)：\(count)/\(quota.limit) · 免费版", "\(quota.label): \(count)/\(quota.limit) · Free plan"))
                    .font(.caption).foregroundStyle(.secondary)
                if count >= quota.limit {
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    ProUpgradeButton()
                }
            }
        }
    }
}

/// Shown where the plan decides the content, until this launch has verified it.
struct ProStatusPending: View {
    var store = PurchaseStore.shared
    var body: some View {
        if store.accessUnavailable {
            ContentUnavailableView {
                Label(L("暂时无法确认购买状态", "Purchase status could not be confirmed"), systemImage: "exclamationmark.icloud")
            } description: {
                Text(L("你的数据不受影响。请检查网络后重试。", "Your data is unaffected. Check your connection and retry."))
            } actions: {
                Button(L("重新验证", "Retry verification")) { Task { await store.refresh() } }
            }
        } else {
            ProgressView(L("正在验证购买状态…", "Verifying purchases…")).frame(maxWidth: .infinity, minHeight: 120)
        }
    }
}
