import Foundation

enum ProProduct: String, CaseIterable, Sendable {
    case monthly = "local.jianshi.personal.pro.monthly"
    case annual = "local.jianshi.personal.pro.annual"
    case lifetime = "local.jianshi.personal.pro.lifetime"

    var title: String {
        switch self {
        case .monthly: L("月付 Pro", "Monthly Pro")
        case .annual: L("年付 Pro", "Annual Pro")
        case .lifetime: L("买断 Pro", "Lifetime Pro")
        }
    }
    var billing: String {
        switch self {
        case .monthly: L("每月，自动续订", "per month, auto-renewing")
        case .annual: L("每年，自动续订", "per year, auto-renewing")
        case .lifetime: L("一次购买", "one-time purchase")
        }
    }
}

struct PurchaseOffer: Identifiable, Equatable, Sendable {
    let product: ProProduct
    let price: String
    var id: String { product.rawValue }
}

enum PurchaseCatalog {
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let subscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!
    // Set a published policy before enabling real purchases; never invent a policy address.
    static var privacyURL: URL? {
        let key = L("TallyPrivacyPolicyURL", "TallyPrivacyPolicyEnglishURL")
        let text = Bundle.main.object(forInfoDictionaryKey: key)
            ?? Bundle.main.object(forInfoDictionaryKey: "TallyPrivacyPolicyURL")
        guard let text = text as? String,
              let url = URL(string: text), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}
