import Foundation
import SwiftData

@Model
final class SDTransactionEntity {
    @Attribute(.unique) var id: UUID

    var accountID: UUID

    var sourceRaw: String
    var externalID: String?
    var sourceFingerprint: String?

    var statusRaw: String
    var kindRaw: String?

    var amountValue: String
    var amountCurrencyRaw: String

    var bookedAt: Date?
    var authorizedAt: Date?
    var valueDate: Date?
    var effectiveDateValue: Date?

    var rawDescription: String?
    var rawMerchantName: String?

    var merchantID: UUID?
    var merchantDisplayName: String?

    var categoryID: UUID?

    var paymentMethodRaw: String?

    var originalCurrencyRaw: String?
    var originalAmountValue: String?

    var cryptoAsset: String?
    var cryptoAmountValue: String?

    var cashbackAmountValue: String?
    var cashbackCurrencyRaw: String?
    var importBatchID: UUID?
    var searchableText: String?
    var note: String?

    var reviewed: Bool?
    var excludedFromAnalytics: Bool?
    var tagIDsJSON: Data?

    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        accountID: UUID,
        sourceRaw: String,
        externalID: String?,
        sourceFingerprint: String?,
        statusRaw: String,
        kindRaw: String?,
        amountValue: String,
        amountCurrencyRaw: String,
        bookedAt: Date?,
        authorizedAt: Date?,
        valueDate: Date?,
        effectiveDateValue: Date?,
        rawDescription: String?,
        rawMerchantName: String?,
        merchantID: UUID?,
        merchantDisplayName: String?,
        categoryID: UUID?,
        paymentMethodRaw: String?,
        originalCurrencyRaw: String?,
        originalAmountValue: String?,
        cryptoAsset: String?,
        cryptoAmountValue: String?,
        cashbackAmountValue: String?,
        cashbackCurrencyRaw: String?,
        importBatchID: UUID?,
        searchableText: String?,
        note: String?,
        reviewed: Bool?,
        excludedFromAnalytics: Bool?,
        tagIDsJSON: Data? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.accountID = accountID
        self.sourceRaw = sourceRaw
        self.externalID = externalID
        self.sourceFingerprint = sourceFingerprint
        self.statusRaw = statusRaw
        self.kindRaw = kindRaw
        self.amountValue = amountValue
        self.amountCurrencyRaw = amountCurrencyRaw
        self.bookedAt = bookedAt
        self.authorizedAt = authorizedAt
        self.valueDate = valueDate
        self.effectiveDateValue = effectiveDateValue
        self.rawDescription = rawDescription
        self.rawMerchantName = rawMerchantName
        self.merchantID = merchantID
        self.merchantDisplayName = merchantDisplayName
        self.categoryID = categoryID
        self.paymentMethodRaw = paymentMethodRaw
        self.originalCurrencyRaw = originalCurrencyRaw
        self.originalAmountValue = originalAmountValue
        self.cryptoAsset = cryptoAsset
        self.cryptoAmountValue = cryptoAmountValue
        self.cashbackAmountValue = cashbackAmountValue
        self.cashbackCurrencyRaw = cashbackCurrencyRaw
        self.importBatchID = importBatchID
        self.searchableText = searchableText
        self.note = note
        self.reviewed = reviewed
        self.excludedFromAnalytics = excludedFromAnalytics
        self.tagIDsJSON = tagIDsJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
