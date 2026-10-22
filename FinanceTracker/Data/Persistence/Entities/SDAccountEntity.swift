import Foundation
import SwiftData

@Model
final class SDAccountEntity {
    @Attribute(.unique) var id: UUID
    var connectionID: UUID?
    var institutionID: String?
    var name: String
    var typeRaw: String
    var currencyRaw: String
    var maskedIdentifier: String?
    var ibanLast4: String?
    var providerAccountID: String?
    var sourceRaw: String
    var isActive: Bool

    init(
        id: UUID,
        connectionID: UUID?,
        institutionID: String?,
        name: String,
        typeRaw: String,
        currencyRaw: String,
        maskedIdentifier: String?,
        ibanLast4: String?,
        providerAccountID: String?,
        sourceRaw: String,
        isActive: Bool
    ) {
        self.id = id
        self.connectionID = connectionID
        self.institutionID = institutionID
        self.name = name
        self.typeRaw = typeRaw
        self.currencyRaw = currencyRaw
        self.maskedIdentifier = maskedIdentifier
        self.ibanLast4 = ibanLast4
        self.providerAccountID = providerAccountID
        self.sourceRaw = sourceRaw
        self.isActive = isActive
    }
}
