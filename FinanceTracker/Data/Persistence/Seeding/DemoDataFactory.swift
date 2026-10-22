import Foundation

struct DemoDataSet: Sendable {
    let accounts: [Account]
    let categories: [Category]
    let merchants: [Merchant]
    let transactions: [Transaction]
    var commitments: [RecurringCommitment] = []
    var budgets: [Budget] = []
    var transactionCollections: [TransactionCollection] = []
}

struct SeededRandom: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(nextUInt64() % UInt64(range.count))
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        let fraction = Double(nextUInt64() % 1_000_000) / 1_000_000
        return range.lowerBound + fraction * (range.upperBound - range.lowerBound)
    }

    mutating func decimal(in range: ClosedRange<Double>, scale: Int = 2) -> Decimal {
        let value = double(in: range)
        let multiplier = pow(10.0, Double(scale))
        let rounded = (value * multiplier).rounded() / multiplier
        return Decimal(string: String(format: "%.\(scale)f", rounded)) ?? 0
    }
}

enum DemoDataFactory {
    static func make(now: Date = Date()) -> DemoDataSet {
        let calendar = Calendar.current
        var rng = SeededRandom(seed: 0x46494E4345545241)

        let categories = Category.defaultCatalog()

        let giroAccount = Account(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            name: String(localized: "Girokonto"),
            type: .checking,
            currency: .eur,
            maskedIdentifier: "•••• 4821",
            ibanLast4: "4821",
            source: .demo
        )
        let visaCard = Account(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            name: String(localized: "Visa Kreditkarte"),
            type: .creditCard,
            currency: .eur,
            maskedIdentifier: "•••• 1207",
            source: .demo
        )
        let mastercard = Account(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
            name: "Mastercard",
            type: .creditCard,
            currency: .eur,
            maskedIdentifier: "•••• 8341",
            source: .demo
        )
        // Bargeld mit Anfangsbestand: zeigt den echten Kontostand („Stand")
        // statt nur der Netto-Bewegung (Previews/Galerie).
        let wallet = Account(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000005")!,
            name: String(localized: "Geldbeutel"),
            type: .cash,
            currency: .eur,
            source: .demo,
            openingBalance: 150,
            openingBalanceDate: calendar.date(byAdding: .day, value: -20, to: calendar.startOfDay(for: now))
        )
        let accounts = [giroAccount, visaCard, mastercard, wallet]

        func merchant(_ name: String, aliases: [String] = []) -> Merchant {
            Merchant(displayName: name, aliases: aliases)
        }

        let merchants = [
            merchant("REWE", aliases: ["REWE SAGT DANKE"]),
            merchant("BILLA"),
            merchant("SPAR"),
            merchant("LIDL"),
            merchant("HOFER"),
            merchant("Amazon", aliases: ["AMZN MKTP DE", "AMAZON.ES"]),
            merchant("SPOTIFY"),
            merchant("NETFLIX"),
            merchant("SHELL"),
            merchant("Wiener Linien"),
            merchant("Apple", aliases: ["APPLE.COM/BILL"]),
            merchant("dm"),
            merchant("McDonald's"),
            merchant("Uber"),
            merchant("Zalando"),
            merchant("Acme GmbH", aliases: ["GEHALT ACME GMBH"]),
            merchant("Vermieter Musterstraße")
        ]

        let grocers = [("REWE", Category.groceries.id), ("BILLA", Category.groceries.id), ("SPAR", Category.groceries.id), ("LIDL", Category.groceries.id), ("HOFER", Category.groceries.id)]
        let restaurantNames = ["Mcdonald's", "Pizzeria Roma", "Kebap Haus", "Café Central"]

        var transactions: [Transaction] = []
        var externalCounter = 0

        func append(
            account: Account,
            rawMerchant: String,
            displayName: String,
            categoryID: UUID?,
            amount: Decimal,
            day: Date,
            paymentMethod: PaymentMethod?,
            kind: TransactionKind = .purchase,
            currency: CurrencyCode = .eur,
            cryptoAsset: String? = nil,
            cryptoAmount: Decimal? = nil,
            cashbackAmount: Decimal? = nil,
            status: TransactionStatus = .booked
        ) {
            externalCounter += 1
            var bookingDate: Date?
            var authorizedDate: Date?
            if status == .booked {
                bookingDate = day
            } else {
                authorizedDate = day
            }
            let txn = Transaction(
                accountID: account.id,
                source: .demo,
                externalID: "demo-\(externalCounter)",
                sourceFingerprint: TransactionFingerprinter.fingerprint(
                    source: .demo,
                    accountID: account.id,
                    bookingDate: bookingDate ?? authorizedDate,
                    amount: Money(amount: amount, currency: currency),
                    merchantOrDescription: rawMerchant
                ),
                status: status,
                kind: kind,
                amount: Money(amount: amount, currency: currency),
                bookedAt: bookingDate,
                authorizedAt: authorizedDate,
                rawDescription: "\(rawMerchant) \(rng.int(in: 100_000...999_999))",
                rawMerchantName: rawMerchant,
                merchantDisplayName: displayName,
                categoryID: categoryID,
                paymentMethod: paymentMethod,
                cryptoAsset: cryptoAsset,
                cryptoAmount: cryptoAmount,
                cashbackAmount: cashbackAmount,
                cashbackCurrency: cashbackAmount != nil ? .eur : nil
            )
            transactions.append(txn)
        }

        // Barzahlungen der letzten drei Wochen (deterministisch, ohne den
        // seeded RNG zu verschieben): Stand = 150 − 41,10 = 108,90 €.
        let cashPurchases: [(daysAgo: Int, merchant: String, display: String, category: UUID, amount: String)] = [
            (18, "BAECKEREI MUELLER", String(localized: "Bäckerei Müller"), Category.groceries.id, "4.80"),
            (15, "KIOSK AM PLATZ", String(localized: "Kiosk am Platz"), Category.groceries.id, "6.50"),
            (11, "WOCHENMARKT STAND 12", String(localized: "Wochenmarkt"), Category.groceries.id, "12.30"),
            (8, "BAECKEREI MUELLER", String(localized: "Bäckerei Müller"), Category.groceries.id, "3.90"),
            (5, "CAFE CENTRAL", "Café Central", Category.restaurants.id, "9.40"),
            (2, "KIOSK AM PLATZ", String(localized: "Kiosk am Platz"), Category.groceries.id, "4.20")
        ]
        for purchase in cashPurchases {
            append(
                account: wallet,
                rawMerchant: purchase.merchant,
                displayName: purchase.display,
                categoryID: purchase.category,
                amount: -Decimal(string: purchase.amount)!,
                day: calendar.date(byAdding: .day, value: -purchase.daysAgo, to: calendar.startOfDay(for: now))!,
                paymentMethod: .cash
            )
        }

        let startOfDay180 = calendar.date(byAdding: .day, value: -179, to: calendar.startOfDay(for: now))!

        for dayOffset in 0...179 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfDay180) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            let dayOfMonth = calendar.component(.day, from: day)

            if day == calendar.startOfDay(for: now) {
                continue
            }

            if rng.double(in: 0...1) < 0.45 {
                let grocer = grocers[rng.int(in: 0...(grocers.count - 1))]
                let amount = rng.decimal(in: 12...68)
                let useMastercard = rng.double(in: 0...1) < 0.18
                let account = useMastercard ? mastercard : (rng.double(in: 0...1) < 0.6 ? giroAccount : visaCard)
                append(
                    account: account,
                    rawMerchant: "\(grocer.0.uppercased()) \(rng.int(in: 1000...9999)) FILIALE",
                    displayName: grocer.0,
                    categoryID: grocer.1,
                    amount: -amount,
                    day: day,
                    paymentMethod: .cardPresent,
                    cashbackAmount: useMastercard ? (amount * Decimal(string: "0.01")!).roundedToCents() : nil,
                    status: dayOffset > 176 ? .pending : .booked
                )
            }

            if rng.double(in: 0...1) < 0.16 {
                let name = restaurantNames[rng.int(in: 0...(restaurantNames.count - 1))]
                let useMastercard = rng.double(in: 0...1) < 0.25
                let amount = rng.decimal(in: 9...48)
                append(
                    account: useMastercard ? mastercard : visaCard,
                    rawMerchant: name.uppercased(),
                    displayName: name,
                    categoryID: Category.restaurants.id,
                    amount: -amount,
                    day: day,
                    paymentMethod: .cardPresent,
                    status: dayOffset > 177 ? .pending : .booked
                )
            }

            if dayOffset % 9 == 3 {
                append(
                    account: giroAccount,
                    rawMerchant: "SHELL \(rng.int(in: 100...999))",
                    displayName: "SHELL",
                    categoryID: Category.fuel.id,
                    amount: -rng.decimal(in: 42...78),
                    day: day,
                    paymentMethod: .cardPresent
                )
            }

            if dayOfMonth == 1 {
                append(
                    account: giroAccount,
                    rawMerchant: "WIENER LINIEN JAHRESKARTE",
                    displayName: "Wiener Linien",
                    categoryID: Category.publicTransport.id,
                    amount: -Decimal(string: "33.90")!,
                    day: day,
                    paymentMethod: .directDebit
                )
                append(
                    account: giroAccount,
                    rawMerchant: "MIETE MUSTERSTRASSE 12",
                    displayName: String(localized: "Vermieter Musterstraße"),
                    categoryID: Category.rent.id,
                    amount: -Decimal(string: "985.00")!,
                    day: day,
                    paymentMethod: .standingOrder
                )
            }

            if dayOfMonth == 3 {
                append(
                    account: giroAccount,
                    rawMerchant: "SPOTIFY AB STOCKHOLM",
                    displayName: "SPOTIFY",
                    categoryID: Category.subscriptions.id,
                    amount: -Decimal(string: "10.99")!,
                    day: day,
                    paymentMethod: .directDebit
                )
            }

            if dayOfMonth == 14 {
                append(
                    account: giroAccount,
                    rawMerchant: "NETFLIX.COM",
                    displayName: "NETFLIX",
                    categoryID: Category.subscriptions.id,
                    amount: -Decimal(string: "13.99")!,
                    day: day,
                    paymentMethod: .cardOnline
                )
            }

            if dayOfMonth == 7 {
                append(
                    account: visaCard,
                    rawMerchant: "APPLE.COM/BILL ITUNES.COM",
                    displayName: "Apple",
                    categoryID: Category.subscriptions.id,
                    amount: -Decimal(string: "2.99")!,
                    day: day,
                    paymentMethod: .cardOnline
                )
            }

            if rng.double(in: 0...1) < 0.06 {
                let amount = rng.decimal(in: 11...95)
                append(
                    account: visaCard,
                    rawMerchant: "AMZN MKTP DE*\(rng.int(in: 10...99))AB\(rng.int(in: 100...999))",
                    displayName: "Amazon",
                    categoryID: Category.shopping.id,
                    amount: -amount,
                    day: day,
                    paymentMethod: .cardOnline
                )
            }

            if weekday == 6 && rng.double(in: 0...1) < 0.35 {
                append(
                    account: mastercard,
                    rawMerchant: "UBER TRIP HELPER",
                    displayName: "Uber",
                    categoryID: Category.taxi.id,
                    amount: -rng.decimal(in: 8...29),
                    day: day,
                    paymentMethod: .cardOnline
                )
            }

            if rng.double(in: 0...1) < 0.03 {
                append(
                    account: giroAccount,
                    rawMerchant: "DM DROGERIE MARKT \(rng.int(in: 100...999))",
                    displayName: "dm",
                    categoryID: Category.health.id,
                    amount: -rng.decimal(in: 5...40),
                    day: day,
                    paymentMethod: .cardPresent
                )
            }

            if dayOfMonth == 1 {
                append(
                    account: giroAccount,
                    rawMerchant: "GEHALT ACME GMBH",
                    displayName: "Acme GmbH",
                    categoryID: Category.income.id,
                    amount: Decimal(string: "2850.00")!,
                    day: day,
                    paymentMethod: .bankTransfer,
                    kind: .income
                )
            }
        }

        // Bewusst prüfwürdige Buchungen für Review Queue & Fremdwährungshinweis
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: calendar.startOfDay(for: now))!
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: now))!

        append(
            account: giroAccount,
            rawMerchant: "UNBEKANNTER HANDEL \(rng.int(in: 1000...9999))",
            displayName: String(localized: "Unbekannter Händler"),
            categoryID: nil,
            amount: -Decimal(string: "42.50")!,
            day: threeDaysAgo,
            paymentMethod: .cardPresent
        )

        append(
            account: visaCard,
            rawMerchant: "STARBUCKS STORE US \(rng.int(in: 1000...9999))",
            displayName: "Starbucks",
            categoryID: Category.restaurants.id,
            amount: -Decimal(string: "6.85")!,
            day: twoDaysAgo,
            paymentMethod: .cardOnline,
            currency: .usd
        )

        // Demo-Fixkosten: Miete + Gehalt (Income), zeigt Fixkosten &
        // Abos und aktiviert den Forecast-Hero (Roadmap #112/#117/#126).
        // WP7: Die geplanten Termine (nextExpectedDate) machen die
        // Commitments für den occurrences-basierten Forecast planbar:
        // Miete und Gehalt jeweils am 1.
        let calendar2 = Calendar(identifier: .gregorian)
        let monthStart = calendar2.date(from: calendar2.dateComponents([.year, .month], from: now)) ?? now
        let rentDue = calendar2.date(byAdding: .day, value: 0, to: monthStart) ?? now
        let salaryDue = calendar2.date(byAdding: .month, value: 1, to: monthStart) ?? now
        let demoCommitments = [
            RecurringCommitment(
                name: String(localized: "Miete"),
                merchantKey: "MIETE MUSTERSTRASSE",
                direction: .expense,
                cadence: .monthly,
                amountPolicy: .fixed,
                expectedAmount: Decimal(string: "985.00")!,
                currency: .eur,
                categoryID: Category.rent.id,
                nextExpectedDate: rentDue,
                status: .active,
                origin: .manual
            ),
            RecurringCommitment(
                name: String(localized: "Gehalt Acme GmbH"),
                merchantKey: "GEHALT ACME GMBH",
                direction: .income,
                cadence: .monthly,
                amountPolicy: .fixed,
                expectedAmount: Decimal(string: "2850.00")!,
                currency: .eur,
                nextExpectedDate: salaryDue,
                status: .active,
                origin: .manual,
                createdAt: now
            )
        ]

        // Demo-Budgets (Roadmap #102): machen Forecast-Hero + Budgets demo-fähig
        let demoBudgets = [
            Budget(
                name: String(localized: "Lebensmittel"),
                systemIconName: "cart",
                amount: Decimal(string: "500.00")!,
                currency: .eur,
                categoryIDs: [Category.groceries.id]
            ),
            Budget(
                name: "Shopping",
                systemIconName: "bag",
                amount: Decimal(string: "150.00")!,
                currency: .eur,
                categoryIDs: [Category.shopping.id]
            )
        ]

        let startOfToday = calendar.startOfDay(for: now)
        let demoPockets: [TransactionCollection]
        do {
            demoPockets = [
                try TransactionCollection(
                    id: UUID(uuidString: "70000000-0000-0000-0000-000000000001")!,
                    name: String(localized: "Sommer in Wien"),
                    systemIconName: "tram",
                    startDate: calendar.date(byAdding: .day, value: -21, to: startOfToday)!,
                    endDateExclusive: calendar.date(byAdding: .day, value: 8, to: startOfToday)!,
                    accountIDs: [giroAccount.id, visaCard.id],
                    createdAt: now,
                    updatedAt: now
                ),
                try TransactionCollection(
                    id: UUID(uuidString: "70000000-0000-0000-0000-000000000002")!,
                    name: String(localized: "Herbsturlaub"),
                    systemIconName: "airplane",
                    startDate: calendar.date(byAdding: .day, value: 14, to: startOfToday)!,
                    endDateExclusive: calendar.date(byAdding: .day, value: 22, to: startOfToday)!,
                    accountIDs: [visaCard.id],
                    createdAt: now,
                    updatedAt: now
                ),
                try TransactionCollection(
                    id: UUID(uuidString: "70000000-0000-0000-0000-000000000003")!,
                    name: String(localized: "Frühlingsausflug"),
                    systemIconName: "leaf",
                    startDate: calendar.date(byAdding: .day, value: -90, to: startOfToday)!,
                    endDateExclusive: calendar.date(byAdding: .day, value: -59, to: startOfToday)!,
                    accountIDs: [mastercard.id],
                    createdAt: now,
                    updatedAt: now
                )
            ]
        } catch {
            preconditionFailure("Invalid deterministic demo pocket: \(error)")
        }

        return DemoDataSet(
            accounts: accounts,
            categories: categories,
            merchants: merchants,
            transactions: transactions,
            commitments: demoCommitments,
            budgets: demoBudgets,
            transactionCollections: demoPockets
        )
    }
}

private extension Decimal {
    func roundedToCents() -> Decimal { roundedToCentsInternal(scale: 2) }

    private func roundedToCentsInternal(scale: Int) -> Decimal {
        let handler = NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: Int16(clamping: scale),
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )
        return NSDecimalNumber(decimal: self).rounding(accordingToBehavior: handler).decimalValue
    }
}
