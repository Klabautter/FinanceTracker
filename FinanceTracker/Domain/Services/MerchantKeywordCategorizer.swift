import Foundation

/// Liest die Kategorie aus dem Händlernamen, wenn er sie ausspricht
/// („GINZA SUSHI", „Stadtapotheke", „Bäckerei Muster") oder eine bekannte
/// Kette bzw. Marke nennt.
///
/// Letzte Stufe nach Nutzer- und Systemregeln: Sie greift nur für Buchungen
/// ohne Kategorie und nur bei eindeutigen Wörtern. Namen ohne ein solches
/// Wort bleiben unkategorisiert und landen in der Prüfliste: es gibt keinen
/// Auffang-Treffer für Unbekanntes.
///
/// Geprüft wird der Anzeigename und der ungekürzte Händlertext der Bank
/// (dort steht z. B. „WIENER L 2026…", während der Anzeigename „WIENER"
/// lautet). Freie Verwendungszwecke neben einem Händlernamen bleiben außen
/// vor: „Danke fürs Restaurant" macht eine Überweisung nicht zum Lokal.
enum MerchantKeywordCategorizer {
    private enum Direction {
        case expense, income, any
    }

    private struct Entry {
        let category: Category
        var direction: Direction = .expense
        /// Ganze Wörter oder Wortfolgen (Schreibweise wie nach
        /// `CategoryRuleEngine.normalizedKey`: groß, ohne Umlautpunkte,
        /// Satzzeichen als Leerzeichen).
        let words: [String]
        /// Wortbestandteile („APOTHEKE" trifft auch „STADTAPOTHEKE").
        var parts: [String] = []
    }

    /// Reihenfolge = Priorität: Eindeutiges und Marken vor allgemeinen Wörtern.
    private static let entries: [Entry] = [
        Entry(
            category: .income,
            direction: .income,
            words: [
                "INTEREST", "ZINSEN", "ZINSGUTSCHRIFT", "HABENZINSEN", "DIVIDEND", "DIVIDENDE", "SAVEBACK",
                "CASH REWARD", "GEHALT", "LOHN", "SALARY", "BEZUGE", "BEZUEGE"
            ]
        ),
        Entry(
            category: .investments,
            direction: .any,
            words: [
                "VORABPAUSCHALE", "KAPITALERTRAGSTEUER", "TAX OPTIMISATION", "STEUEROPTIMIERUNG",
                "WARRANT EXERCISE", "DEPOTGEBUHR", "DEPOTGEBUEHR", "ORDERGEBUHR", "ORDERGEBUEHR"
            ],
            parts: ["WERTPAPIER"]
        ),
        Entry(
            category: .rent,
            words: ["MIETE", "AKADEMIKERHILFE", "HOME4STUDENTS", "STUWO", "WIHAST", "STUDENTENWERK", "STUDIERENDENWERK"],
            parts: ["HAUSVERWALT", "WOHNBAU", "WOHNUNGSGESELLSCHAFT", "WOHNUNGSGENOSSENSCHAFT"]
        ),
        Entry(
            category: .subscriptions,
            words: [
                "NETFLIX", "SPOTIFY", "DISNEY", "YOUTUBE", "OPENAI", "CHATGPT", "ANTHROPIC", "CLAUDE AI",
                "PERPLEXITY", "GITHUB", "ICLOUD", "DROPBOX", "ADOBE", "MICROSOFT", "AUDIBLE", "DAZN", "PATREON",
                "NOTION", "MIDJOURNEY", "BOOKBEAT", "BLINKIST", "LANGUAGETOOL", "GRAMMARLY", "DEEPL", "DUOLINGO",
                "HEADSPACE", "STRAVA", "LINKEDIN", "XING", "ZOOM", "SLACK", "FIGMA", "CANVA", "JETBRAINS",
                "1PASSWORD", "BITWARDEN", "NORDVPN", "EXPRESSVPN", "PROTON", "HETZNER", "DIGITALOCEAN", "AWS",
                "CLOUDFLARE", "NAMECHEAP", "GODADDY", "IONOS", "STRATO", "GOOGLE ONE", "GOOGLE PLAY",
                "GOOGLE STORAGE", "GOOGLE WORKSPACE", "AMAZON PRIME", "PRIME VIDEO", "AMAZON MUSIC",
                "APPLE MUSIC", "KINDLE", "DEEZER", "TIDAL", "PLAYSTATION", "XBOX", "NINTENDO", "STEAM",
                "STEAMGAMES", "EPIC GAMES", "TWITCH", "RTL", "JOYN", "ZATTOO", "WAIPU", "PARAMOUNT", "HBO",
                "CRUNCHYROLL", "NYTIMES", "VODAFONE", "TELEKOM", "MAGENTA", "O2", "YESSS", "SPUSU", "CONGSTAR",
                "FREENET", "1UND1", "RUNDFUNK", "RUNDFUNKBEITRAG", "ORF BEITRAG", "MCFIT", "FITINN", "JOHN REED",
                "URBAN SPORTS", "GYM", "ABO", "ABONNEMENT", "SUBSCRIPTION", "MEMBERSHIP", "MITGLIEDSBEITRAG"
            ],
            parts: ["FITNESS", "ZEITUNG"]
        ),
        Entry(
            category: .fuel,
            words: [
                "TANKSTELLE", "OMV", "ESSO", "AVIA", "TURMOL", "TOTALENERGIES", "BP", "ENI", "AGIP", "Q8",
                "TAMOIL", "CIRCLE K", "OKQ8", "PREEM", "REPSOL", "CEPSA", "LUKOIL", "ORLEN", "SOCAR",
                "CARBURANT", "BENZINA", "GASOLINERA", "DISKONT TANK"
            ],
            parts: ["TANKSTELLE"]
        ),
        Entry(
            category: .publicTransport,
            words: [
                "WIENER L", "LINIEN", "OEBB", "OBB", "BAHN", "WESTBAHN", "FLIXBUS", "FLIXTRAIN", "REGIOJET",
                "TRENITALIA", "RENFE", "SNCF", "SBB", "DSB", "TFL", "RATP", "TRAINLINE", "OMIO",
                "MVV", "MVG", "BVG", "HVV", "VVS", "KVB", "RMV", "VGN", "IVB", "POSTBUS", "KLIMATICKET",
                "DEUTSCHLANDTICKET", "VERKEHRSBETRIEBE", "VERKEHRSVERBUND", "NEXTBIKE", "CITYBIKE", "TIER MOBILITY"
            ],
            parts: ["VERKEHRSBETRIEB", "VERKEHRSVERBUND", "VERKEHRSGESELLSCHAFT", "EISENBAHN"]
        ),
        Entry(
            category: .taxi,
            words: ["TAXI", "BOLT", "FREENOW", "FREE NOW", "MYTAXI", "CABIFY", "LYFT"],
            parts: ["TAXI"]
        ),
        Entry(
            category: .travel,
            words: [
                "HOTEL", "HOSTEL", "HOSTAL", "MOTEL", "ALBERGO", "RESORT", "PENSION", "GARNI", "AIRBNB",
                "BOOKING", "BOOKING COM", "HOTELS COM", "EXPEDIA", "TRIVAGO", "HRS", "TUI", "LUFTHANSA",
                "RYANAIR", "EASYJET", "EUROWINGS", "WIZZ", "VUELING", "TRANSAVIA", "NORWEGIAN", "CONDOR",
                "TUIFLY", "KLM", "AIR FRANCE", "AIRLINES", "AIRLINE", "AIRWAYS", "CAMPING", "CAMPEGGIO",
                "JUGENDHERBERGE", "FERIENWOHNUNG", "GASTEHAUS", "GAESTEHAUS", "SIXT", "EUROPCAR", "HERTZ",
                "SEILBAHN", "FUNIVIA", "FUNIVIE", "SKIPASS", "SKILIFT"
            ],
            parts: ["HOTEL", "CAMPINGPLATZ", "BERGBAHN"]
        ),
        Entry(
            category: .health,
            words: [
                "APOTHEKE", "PHARMACY", "PHARMACIE", "FARMACIA", "ARZT", "DOCTOR", "PRAXIS", "ORDINATION",
                "KLINIK", "KRANKENHAUS", "SPITAL", "HOSPITAL", "MEDICAL", "DENTAL", "DENTIST", "OPTIKER", "OPTIK",
                "PHYSIO", "DROGERIE", "ROSSMANN", "BIPA", "DOCMORRIS", "FIELMANN"
            ],
            parts: ["APOTHEKE", "ZAHNARZT", "ZAHNKLINIK", "ARZTPRAXIS", "OPTIK", "PHYSIOTHERAP"]
        ),
        Entry(
            category: .groceries,
            words: [
                "SUPERMARKT", "SUPERMARKET", "SUPERMERCATO", "LEBENSMITTEL", "BAKERY", "BOULANGERIE",
                "PANADERIA", "PANIFICIO", "BAGER", "BAGERI", "BIOMARKT", "FEINKOST", "GROCERY", "ALIMENTARI",
                "EPICERIE", "HOFLADEN", "WOCHENMARKT", "MPREIS", "INTERSPAR", "EUROSPAR", "DESPAR", "CONAD",
                "UNIMARKT", "ADEG", "DENNS", "DENN S", "BIO COMPANY", "ALNATURA", "NORMA", "FAMILA",
                "MARKTKAUF", "NAHKAUF", "FENEBERG", "COOP", "MIGROS", "DENNER", "CARREFOUR", "AUCHAN",
                "LECLERC", "INTERMARCHE", "MERCADONA", "ESSELUNGA", "TESCO", "SAINSBURY", "WAITROSE", "ICA",
                "WILLYS", "FOTEX", "REMA", "BILKA", "ALBERT HEIJN", "DELHAIZE", "BIEDRONKA", "ZABKA", "FLINK",
                "GORILLAS", "KNUSPR", "PICNIC", "HELLOFRESH", "GETRANKEMARKT", "GETRAENKEMARKT", "SUPERSTORE",
                "BAGUETTE"
            ],
            parts: ["BACKER", "BAECKER", "BACKSTUBE", "METZGER", "FLEISCHER", "SUPERMARKT", "SUPERMERC"]
        ),
        Entry(
            category: .restaurants,
            words: [
                "SUSHI", "PIZZA", "PIZZERIA", "RESTAURANT", "RESTAURANTE", "RESTAURANG", "RISTORANTE",
                "TRATTORIA", "OSTERIA", "BRASSERIE", "TAVERNE", "TAVERNA", "TABERNA", "BIRRERIA", "CREPERIE",
                "GASTHAUS", "GASTHOF", "GASTSTATTE", "GASTSTAETTE", "WIRTSHAUS", "BRAUHAUS", "BRAUEREI",
                "BIERGARTEN", "WEINSTUBE", "BEISL", "HEURIGER", "HUTTE", "HUETTE", "IMBISS", "KEBAB", "KEBAP",
                "DONER", "DOENER", "FALAFEL", "SHAWARMA", "BURGER", "BURGERS", "STEAKHOUSE", "GRILL", "BBQ",
                "BISTRO", "CAFE", "CAFFE", "KAFFEEHAUS", "KONDITOREI", "KONDITORI", "EISDIELE", "EISSALON",
                "PUB", "RAMEN", "NOODLES", "WOK", "POKE", "CURRY", "TACOS", "BURRITO", "DIM SUM", "TAPAS",
                "MENSA", "KANTINE", "DINER", "COFFEE", "ESPRESSO", "BAGEL", "DONUTS", "KFC", "NORDSEE",
                "LOSTERIA", "L OSTERIA", "HANS IM GLUCK", "DUNKIN", "DOMINOS", "DOMINO S", "PIZZA HUT",
                "FIVE GUYS", "CARLS JR", "CARL S JR", "TACO BELL", "MYCHEF", "AUTOGRILL", "SERWAYS", "BACKWERK",
                "DEAN DAVID", "PETER PANE", "BLOCK HOUSE", "WIENERWALD", "SWING KITCHEN", "ESPRESSO HOUSE",
                "JOE THE JUICE", "DELIVEROO", "JUST EAT", "GLOVO", "TOO GOOD TO GO", "LIEFERSERVICE",
                "DELIVERY HERO", "FOODORA", "LIEFERANDO", "WOLT", "MJAM", "UBER EATS"
            ],
            parts: [
                "RESTAURANT", "RESTAURANG", "PIZZ", "GASTHAUS", "GASTHOF", "WIRTSHAUS", "SUSHI", "KEBAP", "KEBAB", "EISCAFE",
                "GASTRO", "GELAT", "KAFFEE", "STUBERL", "STUEBERL"
            ]
        ),
        Entry(
            category: .shopping,
            words: [
                "DECATHLON", "ZALANDO", "ZARA", "H M", "HM COM", "SATURN", "MEDIA MARKT", "CYBERPORT", "CONRAD",
                "ALTERNATE", "APPLE STORE", "SAMSUNG", "PHILIPS", "BOSE", "SONY", "DYSON", "LEGO", "AMZN",
                "AMZN MKTP", "EBAY", "ETSY", "VINTED", "KLEINANZEIGEN", "WILLHABEN", "ABOUT YOU", "ASOS",
                "ALIEXPRESS", "TEMU", "SHEIN", "THALIA", "HUGENDUBEL", "WELTBILD", "MORAWA", "OSIANDER", "HORNBACH",
                "OBI", "BAUHAUS", "TOOM", "HAGEBAU", "LAGERHAUS", "DEHNER", "JYSK", "XXXLUTZ", "MOMAX", "MOEBELIX",
                "KIKA", "LEINER", "POCO", "BUTLERS", "FLYING TIGER", "TK MAXX", "PEEK CLOPPENBURG", "NEW YORKER",
                "PULL BEAR", "BERSHKA", "ESPRIT", "S OLIVER", "TOM TAILOR", "JACK JONES", "LEVIS",
                "NIKE", "ADIDAS", "PUMA", "FOOT LOCKER", "SNIPES", "SPORTSCHECK", "BERGFREUNDE", "GLOBETROTTER",
                "INTERSPORT", "HERVIS", "UNIQLO", "PRIMARK", "DEICHMANN", "HUMANIC", "SCHIESSER", "INTIMISSIMI",
                "CALZEDONIA", "DOUGLAS", "SEPHORA", "RITUALS", "LUSH", "FRESSNAPF", "ZOOPLUS", "FUTTERHAUS",
                "GALERIA", "KARSTADT", "KAUFHOF", "BREUNINGER", "MANUFACTUM", "LIBRO", "PAGRO", "MCPAPER", "TEDI",
                "WOOLWORTH", "KIK", "NKD", "TAKKO", "SWAROVSKI", "PANDORA", "THOMAS SABO", "BIKE", "BIKES",
                "BLUMEN", "GARTENCENTER"
            ],
            parts: ["BUCHHANDLUNG", "BAUMARKT", "MODEHAUS", "KAUFHAUS", "FAHRRAD", "RADHAUS", "ZWEIRAD", "SCHREIBWAREN"]
        ),
        Entry(
            category: .utilities,
            words: [
                "STADTWERKE", "STROM", "FERNWARME", "FERNWAERME", "VATTENFALL", "ENBW", "EON", "RWE", "EWE",
                "EVN", "VERBUND", "KELAG", "TIWAG", "ILLWERKE", "MAINOVA", "TIBBER", "YELLO", "LICHTBLICK",
                "NATURSTROM", "OCTOPUS ENERGY"
            ],
            parts: ["STADTWERKE", "ENERGIE", "WASSERWERK"]
        ),
        // Internationale Ketten (UK, US, FR, ES, IT, NL), damit Exporte
        // außerhalb von Deutschland/Österreich ebenso automatisch zugeordnet werden.
        Entry(
            category: .groceries,
            words: [
                "WHOLE FOODS", "WHOLEFDS", "TRADER JOE", "TRADER JOES", "KROGER", "SAFEWAY", "PUBLIX", "COSTCO",
                "WEGMANS", "MORRISONS", "WAITROSE", "ICELAND FOODS", "CO OP FOOD", "FRANPRIX", "MONOPRIX", "PICARD",
                "LIDL", "ALDI", "ESSELUNGA", "PAM PANORAMA", "EROSKI", "CONSUM", "JUMBO", "PLUS SUPERMARKT", "DIRK VAN DEN BROEK"
            ]
        ),
        Entry(
            category: .restaurants,
            words: [
                "STARBUCKS", "PRET A MANGER", "COSTA COFFEE", "TIM HORTONS", "CHIPOTLE", "SUBWAY",
                "BURGER KING", "WENDYS", "TACO BELL", "PANERA", "GREGGS", "NANDOS", "WAGAMAMA",
                "DOORDASH", "GRUBHUB", "DELIVEROO", "THUISBEZORGD", "GLOVO"
            ]
        ),
        Entry(
            category: .shopping,
            words: [
                "IKEA", "WALMART", "TARGET", "BEST BUY", "HOME DEPOT", "LOWES", "MACYS", "MACY S", "FNAC", "DARTY",
                "EL CORTE INGLES", "MARKS SPENCER", "JOHN LEWIS", "ARGOS", "CURRYS", "BOL COM", "COOLBLUE", "HEMA",
                "ACTION NEDERLAND", "LA RINASCENTE", "UNIEURO", "MEDIAWORLD"
            ]
        ),
        Entry(
            category: .health,
            words: ["BOOTS", "CVS", "CVS PHARMACY", "WALGREENS", "SUPERDRUG", "KRUIDVAT", "ETOS", "PARAFARMACIA"]
        ),
        Entry(
            category: .publicTransport,
            words: [
                "TFL", "TRANSPORT FOR LONDON", "RATP", "NAVIGO", "MTA", "CLIPPER", "OV CHIPKAART",
                "NS GROEP", "NS REIZIGERS", "METRO DE MADRID", "ATM MILANO", "ATAC"
            ]
        ),
        Entry(
            category: .subscriptions,
            words: [
                "MOVISTAR", "T MOBILE", "VERIZON", "SFR", "BOUYGUES TELECOM", "FREE MOBILE", "TIM SPA", "WINDTRE",
                "ILIAD", "KPN", "ODIDO", "GIFFGAFF", "EE LIMITED", "THREE UK"
            ]
        ),
        Entry(
            category: .other,
            words: [
                "STUDIENBEITRAG", "SEMESTERBEITRAG", "UNI WIEN", "UNIVERSITAT", "UNIVERSITAET", "UNIVERSITY",
                "HOCHSCHULE", "FINANZAMT", "MAGISTRAT", "STADTKASSE", "BEZIRKSHAUPTMANNSCHAFT"
            ],
            parts: ["STUDIENBEITRA", "VERSICHERUNG"]
        )
    ]

    static func categoryID(for transaction: Transaction) -> Category.ID? {
        guard transaction.kind != .transfer, !transaction.amount.amount.isZero else { return nil }
        let isIncome = transaction.amount.isPositive
        // Der ungekürzte Händlertext; ein freier Verwendungszweck nur, wenn
        // die Bank keinen eigenen Händlernamen liefert.
        let texts = [transaction.effectiveMerchantName, transaction.rawMerchantName ?? transaction.rawDescription]
        for text in texts.compactMap({ $0 }) {
            if let categoryID = categoryID(forMerchantName: text, isIncome: isIncome) {
                return categoryID
            }
        }
        return nil
    }

    static func categoryID(forMerchantName name: String, isIncome: Bool = false) -> Category.ID? {
        let key = CategoryRuleEngine.normalizedKey(name)
        guard !key.isEmpty else { return nil }
        let tokens = key.split(separator: " ")
        for entry in entries {
            switch entry.direction {
            case .expense where isIncome, .income where !isIncome: continue
            default: break
            }
            let hasWord = entry.words.contains { CategoryRuleEngine.containsTokenSequence(key, $0) }
            let hasPart = entry.parts.contains { part in tokens.contains { $0.contains(part) } }
            if hasWord || hasPart {
                return entry.category.id
            }
        }
        return nil
    }
}
