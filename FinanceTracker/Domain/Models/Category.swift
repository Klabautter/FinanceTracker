import Foundation

enum CategoryColorToken: String, Codable, Sendable, CaseIterable {
    case blue
    case green
    case orange
    case purple
    case red
    case teal
    case yellow
    case indigo
    case gray
}

struct Category: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    var systemIconName: String
    var colorToken: CategoryColorToken
    var parentID: Category.ID?

    init(
        id: UUID = UUID(),
        name: String,
        systemIconName: String,
        colorToken: CategoryColorToken = .gray,
        parentID: Category.ID? = nil
    ) {
        self.id = id
        self.name = name
        self.systemIconName = systemIconName
        self.colorToken = colorToken
        self.parentID = parentID
    }
}

extension Category {
    static let food = Category(
        id: UUID(uuidString: "00000001-0000-0000-0000-000000000000")!,
        name: "Essen & Trinken",
        systemIconName: "fork.knife",
        colorToken: .orange
    )
    static let groceries = Category(
        id: UUID(uuidString: "00000001-0000-0000-0000-000000000001")!,
        name: "Lebensmittel",
        systemIconName: "cart",
        colorToken: .green,
        parentID: Category.food.id
    )
    static let restaurants = Category(
        id: UUID(uuidString: "00000001-0000-0000-0000-000000000002")!,
        name: "Restaurants",
        systemIconName: "cup.and.saucer",
        colorToken: .orange,
        parentID: Category.food.id
    )
    static let mobility = Category(
        id: UUID(uuidString: "00000002-0000-0000-0000-000000000000")!,
        name: "Mobilität",
        systemIconName: "car",
        colorToken: .blue
    )
    static let fuel = Category(
        id: UUID(uuidString: "00000002-0000-0000-0000-000000000001")!,
        name: "Tanken",
        systemIconName: "fuelpump",
        colorToken: .red,
        parentID: Category.mobility.id
    )
    static let publicTransport = Category(
        id: UUID(uuidString: "00000002-0000-0000-0000-000000000002")!,
        name: "ÖPNV",
        systemIconName: "bus",
        colorToken: .teal,
        parentID: Category.mobility.id
    )
    static let taxi = Category(
        id: UUID(uuidString: "00000002-0000-0000-0000-000000000003")!,
        name: "Taxi",
        systemIconName: "car.side",
        colorToken: .indigo,
        parentID: Category.mobility.id
    )
    static let shopping = Category(
        id: UUID(uuidString: "00000003-0000-0000-0000-000000000000")!,
        name: "Shopping",
        systemIconName: "bag",
        colorToken: .purple
    )
    static let subscriptions = Category(
        id: UUID(uuidString: "00000004-0000-0000-0000-000000000000")!,
        name: "Abos",
        systemIconName: "repeat",
        colorToken: .indigo
    )
    static let travel = Category(
        id: UUID(uuidString: "00000005-0000-0000-0000-000000000000")!,
        name: "Reisen",
        systemIconName: "airplane",
        colorToken: .teal
    )
    static let housing = Category(
        id: UUID(uuidString: "00000006-0000-0000-0000-000000000000")!,
        name: "Wohnen",
        systemIconName: "house",
        colorToken: .blue
    )
    static let rent = Category(
        id: UUID(uuidString: "00000006-0000-0000-0000-000000000001")!,
        name: "Miete",
        systemIconName: "key.horizontal",
        colorToken: .blue,
        parentID: Category.housing.id
    )
    static let utilities = Category(
        id: UUID(uuidString: "00000006-0000-0000-0000-000000000002")!,
        name: "Energie & Nebenkosten",
        systemIconName: "bolt.house",
        colorToken: .yellow,
        parentID: Category.housing.id
    )
    static let health = Category(
        id: UUID(uuidString: "00000007-0000-0000-0000-000000000000")!,
        name: "Gesundheit",
        systemIconName: "cross.case",
        colorToken: .red
    )
    static let income = Category(
        id: UUID(uuidString: "00000008-0000-0000-0000-000000000000")!,
        name: "Einkünfte",
        systemIconName: "plus.circle",
        colorToken: .green
    )
    static let transfers = Category(
        id: UUID(uuidString: "00000009-0000-0000-0000-000000000000")!,
        name: "Umbuchungen",
        systemIconName: "arrow.left.arrow.right",
        colorToken: .gray
    )
    static let cash = Category(
        id: UUID(uuidString: "0000000A-0000-0000-0000-000000000000")!,
        name: "Bargeld",
        systemIconName: "banknote",
        colorToken: .yellow
    )
    static let other = Category(
        id: UUID(uuidString: "0000000B-0000-0000-0000-000000000000")!,
        name: "Sonstiges",
        systemIconName: "ellipsis.circle",
        colorToken: .gray
    )

    /// Wertpapierkäufe, Sparpläne und -verkäufe: Geld, das ins Depot fließt
    /// oder von dort zurückkommt.
    static let investments = Category(
        id: UUID(uuidString: "0000000C-0000-0000-0000-000000000000")!,
        name: "Geldanlage",
        systemIconName: "chart.line.uptrend.xyaxis",
        colorToken: .indigo
    )

    static func defaultCatalog() -> [Category] {
        [food, groceries, restaurants,
         mobility, fuel, publicTransport, taxi,
         shopping, subscriptions, travel,
         housing, rent, utilities, health,
         income, transfers, cash, investments, other]
    }
}

extension Category {
    /// Standardkategorien liegen mit ihrem deutschen Namen in der Datenbank.
    /// Solange der Nutzer sie nicht umbenannt hat, erscheinen sie in der
    /// Systemsprache; eigene und umbenannte Kategorien bleiben, wie sie sind.
    static func displayName(id: UUID, storedName: String) -> String {
        guard defaultNamesByID[id] == storedName else { return storedName }
        return localizedDefaultName(id: id) ?? storedName
    }

    private static let defaultNamesByID: [UUID: String] = Dictionary(
        uniqueKeysWithValues: defaultCatalog().map { ($0.id, $0.name) }
    )

    // Literale statt dynamischer Schlüssel, damit der Compiler sie für den
    // String-Katalog findet.
    private static func localizedDefaultName(id: UUID) -> String? {
        switch id {
        case food.id: String(localized: "Essen & Trinken")
        case groceries.id: String(localized: "Lebensmittel")
        case restaurants.id: String(localized: "Restaurants")
        case mobility.id: String(localized: "Mobilität")
        case fuel.id: String(localized: "Tanken")
        case publicTransport.id: String(localized: "ÖPNV")
        case taxi.id: String(localized: "Taxi")
        case shopping.id: String(localized: "Shopping")
        case subscriptions.id: String(localized: "Abos")
        case travel.id: String(localized: "Reisen")
        case housing.id: String(localized: "Wohnen")
        case rent.id: String(localized: "Miete")
        case utilities.id: String(localized: "Energie & Nebenkosten")
        case health.id: String(localized: "Gesundheit")
        case income.id: String(localized: "Einkünfte")
        case transfers.id: String(localized: "Umbuchungen")
        case cash.id: String(localized: "Bargeld")
        case investments.id: String(localized: "Geldanlage")
        case other.id: String(localized: "Sonstiges")
        default: nil
        }
    }
}
