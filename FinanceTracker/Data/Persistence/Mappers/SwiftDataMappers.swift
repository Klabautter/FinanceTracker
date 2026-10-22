import Foundation

extension SDAccountEntity {
    convenience init(from account: Account) {
        self.init(
            id: account.id,
            connectionID: account.connectionID,
            institutionID: account.institutionID,
            name: account.name,
            typeRaw: account.type.rawValue,
            currencyRaw: account.currency.rawValue,
            maskedIdentifier: account.maskedIdentifier,
            ibanLast4: account.ibanLast4,
            providerAccountID: account.providerAccountID,
            sourceRaw: account.source.rawValue,
            isActive: account.isActive
        )
    }

    func update(from account: Account) {
        connectionID = account.connectionID
        institutionID = account.institutionID
        name = account.name
        typeRaw = account.type.rawValue
        currencyRaw = account.currency.rawValue
        maskedIdentifier = account.maskedIdentifier
        ibanLast4 = account.ibanLast4
        providerAccountID = account.providerAccountID
        sourceRaw = account.source.rawValue
        isActive = account.isActive
    }

    /// Anfangsbestand kommt aus dem V13-Sidecar (`SDAccountOpeningBalanceEntity`)
    /// und wird im Model-Actor zusammengeführt.
    func toDomain() -> Account {
        Account(
            id: id,
            connectionID: connectionID,
            institutionID: institutionID,
            name: name,
            type: AccountType(rawValue: typeRaw) ?? .other,
            currency: CurrencyCode(currencyRaw),
            maskedIdentifier: maskedIdentifier,
            ibanLast4: ibanLast4,
            providerAccountID: providerAccountID,
            source: AccountSource(rawValue: sourceRaw) ?? .manual,
            isActive: isActive
        )
    }
}

extension SDCategoryEntity {
    convenience init(from category: Category) {
        self.init(
            id: category.id,
            name: category.name,
            systemIconName: category.systemIconName,
            colorTokenRaw: category.colorToken.rawValue,
            parentID: category.parentID
        )
    }

    func update(from category: Category) {
        name = category.name
        systemIconName = category.systemIconName
        colorTokenRaw = category.colorToken.rawValue
        parentID = category.parentID
    }

    func toDomain() -> Category {
        Category(
            id: id,
            name: Category.displayName(id: id, storedName: name),
            systemIconName: systemIconName,
            colorToken: colorTokenRaw.flatMap(CategoryColorToken.init(rawValue:)) ?? .gray,
            parentID: parentID
        )
    }
}

extension SDMerchantEntity {
    convenience init(from merchant: Merchant) {
        self.init(
            id: merchant.id,
            displayName: merchant.displayName,
            aliases: merchant.aliases
        )
    }

    func update(from merchant: Merchant) {
        displayName = merchant.displayName
        aliases = merchant.aliases
    }

    func toDomain() -> Merchant {
        Merchant(id: id, displayName: displayName, aliases: aliases)
    }
}

extension SDTransactionAnnotationEntity {
    convenience init(from annotation: TransactionAnnotation) {
        self.init(
            id: annotation.id,
            transactionID: annotation.transactionID,
            note: annotation.note,
            reviewed: annotation.reviewed,
            excludedFromAnalytics: annotation.excludedFromAnalytics,
            manualKindOverrideRaw: annotation.manualKindOverride?.rawValue,
            tagIDsJSON: encodeTagIDs(annotation.tagIDs),
            createdAt: annotation.createdAt,
            updatedAt: annotation.updatedAt
        )
    }

    func update(from annotation: TransactionAnnotation) {
        id = annotation.id
        note = annotation.note
        reviewed = annotation.reviewed
        excludedFromAnalytics = annotation.excludedFromAnalytics
        manualKindOverrideRaw = annotation.manualKindOverride?.rawValue
        tagIDsJSON = encodeTagIDs(annotation.tagIDs)
        createdAt = annotation.createdAt
        updatedAt = annotation.updatedAt
    }

    func toDomain() -> TransactionAnnotation {
        TransactionAnnotation(
            id: id,
            transactionID: transactionID,
            note: note,
            reviewed: reviewed,
            excludedFromAnalytics: excludedFromAnalytics,
            manualKindOverride: manualKindOverrideRaw.flatMap(TransactionKind.init(rawValue:)),
            tagIDs: decodeTagIDs(tagIDsJSON),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

extension SDTransactionEntity {
    convenience init(from txn: Transaction) {
        self.init(
            id: txn.id,
            accountID: txn.accountID,
            sourceRaw: txn.source.rawValue,
            externalID: txn.externalID,
            sourceFingerprint: txn.sourceFingerprint,
            statusRaw: txn.status.rawValue,
            kindRaw: txn.kind.rawValue,
            amountValue: Self.decimalString(txn.amount.amount),
            amountCurrencyRaw: txn.amount.currency.rawValue,
            bookedAt: txn.bookedAt,
            authorizedAt: txn.authorizedAt,
            valueDate: txn.valueDate,
            effectiveDateValue: txn.displayDate,
            rawDescription: txn.rawDescription,
            rawMerchantName: txn.rawMerchantName,
            merchantID: txn.merchantID,
            merchantDisplayName: txn.merchantDisplayName,
            categoryID: txn.categoryID,
            paymentMethodRaw: txn.paymentMethod?.rawValue,
            originalCurrencyRaw: txn.originalCurrency?.rawValue,
            originalAmountValue: txn.originalAmount.map(Self.decimalString),
            cryptoAsset: txn.cryptoAsset,
            cryptoAmountValue: txn.cryptoAmount.map(Self.decimalString),
            cashbackAmountValue: txn.cashbackAmount.map(Self.decimalString),
            cashbackCurrencyRaw: txn.cashbackCurrency?.rawValue,
            importBatchID: txn.importBatchID,
            searchableText: Self.buildSearchable(txn),
            note: txn.note,
            reviewed: txn.reviewed,
            excludedFromAnalytics: txn.excludedFromAnalytics,
            tagIDsJSON: encodeTagIDs(txn.tagIDs),
            createdAt: txn.createdAt,
            updatedAt: txn.updatedAt
        )
    }

    func update(from txn: Transaction) {
        accountID = txn.accountID
        sourceRaw = txn.source.rawValue
        externalID = txn.externalID
        sourceFingerprint = txn.sourceFingerprint
        statusRaw = txn.status.rawValue
        kindRaw = txn.kind.rawValue
        amountValue = Self.decimalString(txn.amount.amount)
        amountCurrencyRaw = txn.amount.currency.rawValue
        bookedAt = txn.bookedAt
        authorizedAt = txn.authorizedAt
        valueDate = txn.valueDate
        effectiveDateValue = txn.displayDate
        rawDescription = txn.rawDescription
        rawMerchantName = txn.rawMerchantName
        merchantID = txn.merchantID
        merchantDisplayName = txn.merchantDisplayName
        categoryID = txn.categoryID
        paymentMethodRaw = txn.paymentMethod?.rawValue
        originalCurrencyRaw = txn.originalCurrency?.rawValue
        originalAmountValue = txn.originalAmount.map(Self.decimalString)
        cryptoAsset = txn.cryptoAsset
        cryptoAmountValue = txn.cryptoAmount.map(Self.decimalString)
        cashbackAmountValue = txn.cashbackAmount.map(Self.decimalString)
        cashbackCurrencyRaw = txn.cashbackCurrency?.rawValue
        importBatchID = txn.importBatchID
        searchableText = Self.buildSearchable(txn)
        note = txn.note
        reviewed = txn.reviewed
        excludedFromAnalytics = txn.excludedFromAnalytics
        tagIDsJSON = encodeTagIDs(txn.tagIDs)
        createdAt = txn.createdAt
        updatedAt = txn.updatedAt
    }

    func toDomain() throws -> Transaction {
        guard let amount = Decimal(string: amountValue) else {
            throw PersistenceDecodingError.invalidAmount(field: "amount", raw: amountValue)
        }
        guard let status = TransactionStatus(rawValue: statusRaw) else {
            throw PersistenceDecodingError.unknownStatus(raw: statusRaw)
        }
        guard let source = TransactionSource(rawValue: sourceRaw) else {
            throw PersistenceDecodingError.unknownSource(raw: sourceRaw)
        }

        let originalAmount: Decimal?
        if let originalAmountValue {
            guard let decoded = Decimal(string: originalAmountValue) else {
                throw PersistenceDecodingError.invalidAmount(field: "originalAmount", raw: originalAmountValue)
            }
            originalAmount = decoded
        } else {
            originalAmount = nil
        }

        let cryptoAmount: Decimal?
        if let cryptoAmountValue {
            guard let decoded = Decimal(string: cryptoAmountValue) else {
                throw PersistenceDecodingError.invalidAmount(field: "cryptoAmount", raw: cryptoAmountValue)
            }
            cryptoAmount = decoded
        } else {
            cryptoAmount = nil
        }

        let cashbackAmount: Decimal?
        if let cashbackAmountValue {
            guard let decoded = Decimal(string: cashbackAmountValue) else {
                throw PersistenceDecodingError.invalidAmount(field: "cashback", raw: cashbackAmountValue)
            }
            cashbackAmount = decoded
        } else {
            cashbackAmount = nil
        }

        return Transaction(
            id: id,
            accountID: accountID,
            source: source,
            externalID: externalID,
            sourceFingerprint: sourceFingerprint,
            status: status,
            kind: kindRaw.flatMap(TransactionKind.init(rawValue:)) ?? .unknown,
            amount: Money(
                amount: amount,
                currency: CurrencyCode(amountCurrencyRaw)
            ),
            bookedAt: bookedAt,
            authorizedAt: authorizedAt,
            valueDate: valueDate,
            rawDescription: rawDescription,
            rawMerchantName: rawMerchantName,
            merchantID: merchantID,
            merchantDisplayName: merchantDisplayName,
            categoryID: categoryID,
            paymentMethod: paymentMethodRaw.flatMap(PaymentMethod.init(rawValue:)),
            originalCurrency: originalCurrencyRaw.map(CurrencyCode.init),
            originalAmount: originalAmount,
            cryptoAsset: cryptoAsset,
            cryptoAmount: cryptoAmount,
            cashbackAmount: cashbackAmount,
            cashbackCurrency: cashbackCurrencyRaw.map(CurrencyCode.init),
            note: note,
            reviewed: reviewed ?? false,
            excludedFromAnalytics: excludedFromAnalytics ?? false,
            tagIDs: decodeTagIDs(tagIDsJSON),
            importBatchID: importBatchID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func decimalString(_ value: Decimal) -> String {
        value.description
    }

    static func buildSearchable(_ txn: Transaction) -> String? {
        let parts = [txn.rawMerchantName, txn.rawDescription, txn.merchantDisplayName, txn.note]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Roadmap #162: Suche über Notiz, Tag-Namen liegen nicht auf der
        // Transaktion und werden bei der Suche über die Annotation-Phase
        // berücksichtigt (in-memory).
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
    }
}

extension SDTransactionCollectionEntity {
    convenience init(from collection: TransactionCollection) throws {
        self.init(
            id: collection.id,
            name: collection.name,
            systemIconName: collection.systemIconName,
            startDate: collection.startDate,
            endDateExclusive: collection.endDateExclusive,
            accountIDsJSON: try JSONEncoder().encode(collection.accountIDs),
            createdAt: collection.createdAt,
            updatedAt: collection.updatedAt
        )
    }

    func update(from collection: TransactionCollection) throws {
        name = collection.name
        systemIconName = collection.systemIconName
        startDate = collection.startDate
        endDateExclusive = collection.endDateExclusive
        accountIDsJSON = try JSONEncoder().encode(collection.accountIDs)
        createdAt = collection.createdAt
        updatedAt = collection.updatedAt
    }

    func toDomain() throws -> TransactionCollection {
        let accountIDs: Set<UUID>
        do {
            accountIDs = try JSONDecoder().decode(Set<UUID>.self, from: accountIDsJSON)
        } catch {
            throw PersistenceDecodingError.invalidJSON(field: "transactionCollection.accountIDs")
        }

        do {
            return try TransactionCollection(
                id: id,
                name: name,
                systemIconName: systemIconName,
                startDate: startDate,
                endDateExclusive: endDateExclusive,
                accountIDs: accountIDs,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        } catch {
            throw PersistenceDecodingError.invalidTransactionCollection
        }
    }
}

extension SDTransactionCollectionOverrideEntity {
    convenience init(from override: TransactionCollectionOverride) {
        self.init(
            compositeKey: override.id,
            collectionID: override.collectionID,
            transactionID: override.transactionID,
            decisionRaw: override.decision.rawValue,
            createdAt: override.createdAt,
            updatedAt: override.updatedAt
        )
    }

    func update(from override: TransactionCollectionOverride) {
        compositeKey = override.id
        collectionID = override.collectionID
        transactionID = override.transactionID
        decisionRaw = override.decision.rawValue
        createdAt = override.createdAt
        updatedAt = override.updatedAt
    }

    func toDomain() throws -> TransactionCollectionOverride {
        guard compositeKey == TransactionCollectionOverride.compositeKey(
            collectionID: collectionID,
            transactionID: transactionID
        ) else {
            throw PersistenceDecodingError.invalidJSON(field: "transactionCollectionOverride.compositeKey")
        }
        guard let decision = TransactionCollectionOverrideDecision(rawValue: decisionRaw) else {
            throw PersistenceDecodingError.unknownCollectionOverrideDecision(raw: decisionRaw)
        }
        return TransactionCollectionOverride(
            collectionID: collectionID,
            transactionID: transactionID,
            decision: decision,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}



func encodeTagIDs(_ ids: [UUID]?) -> Data? {
    guard let ids, !ids.isEmpty else { return nil }
    return try? JSONEncoder().encode(ids)
}

func decodeTagIDs(_ data: Data?) -> [UUID]? {
    guard let data else { return nil }
    return try? JSONDecoder().decode([UUID].self, from: data)
}
