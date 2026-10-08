import FeatureContracts
import FeatureContractsUI
import Foundation
import SwiftUI

/// The demo app owns everything the library deliberately leaves open: the
/// feature's contract (three shipped revisions of a receipt extractor), the
/// fleet it is deployed to, the routing budget, and the parity threshold.
/// The library only enforces them.
///
/// Both "models" here are deterministic `ScriptedModel` fixtures. Nothing in
/// this app calls Foundation Models or a hosted LLM; the point is to show
/// the contract, skew and routing machinery around them, end to end.
@main
struct DemoApp: App {
    private let initialTab: ContractConsoleView.Tab

    init() {
        // `-tab router` on the command line lands on a tab (CI screenshots).
        initialTab = UserDefaults.standard.string(forKey: "tab").flatMap(ContractConsoleView.Tab.init(rawValue:)) ?? .fleet
    }

    var body: some Scene {
        WindowGroup {
            ContractConsoleView(scenario: DemoScenario.make(), initialTab: initialTab)
        }
    }
}

// MARK: - The contract (what the app and the server both compile in)

enum ReceiptContract {
    static let id = "expense.extract"
    static let baseCategories = ["food", "travel", "office", "other"]

    static let v10 = ContractRevision(
        version: ContractVersion(1, 0),
        request: ObjectSchema([Field("text", .string(maxLength: 2_000))]),
        response: ObjectSchema([
            Field("merchant", .string(maxLength: 80)),
            Field("total", .number(0...100_000)),
            Field("category", .enumeration(cases: baseCategories)),
        ]),
        promptTemplate: "Extract merchant, total and category from this receipt:\n{{text}}")

    static let v11 = ContractRevision(
        version: ContractVersion(1, 1),
        request: ObjectSchema([
            Field("text", .string(maxLength: 2_000)),
            Field("locale", .string(maxLength: 16), required: false, default: .string("en_US")),
        ]),
        response: ObjectSchema([
            Field("merchant", .string(maxLength: 80)),
            Field("total", .number(0...100_000)),
            Field("category", .enumeration(cases: baseCategories + ["lodging"], fallbacks: ["lodging": "travel"])),
            Field("currency", .string(maxLength: 3), required: false),
        ]),
        promptTemplate: "Extract merchant, total, currency and category (locale {{locale}}) from this receipt:\n{{text}}")

    static let v12 = ContractRevision(
        version: ContractVersion(1, 2),
        request: ObjectSchema([
            Field("text", .string(maxLength: 8_000)),
            Field("locale", .string(maxLength: 16), required: false, default: .string("en_US")),
            Field("hint", .enumeration(cases: ["business", "personal"]), required: false),
        ]),
        response: ObjectSchema([
            Field("merchant", .string(maxLength: 80)),
            Field("total", .number(0...1_000_000)),
            Field("category", .enumeration(cases: baseCategories + ["lodging", "hostel"], fallbacks: ["hostel": "lodging"])),
            Field("currency", .string(maxLength: 3), required: false),
            Field("confidence", .integer(0...100), required: false),
        ]),
        promptTemplate: "Extract merchant, total, currency, category and confidence (locale {{locale}}, hint {{hint}}) from this receipt:\n{{text}}")

    static let shared = FeatureContract(id: id, residency: .serverAllowed, revisions: [v10, v11, v12])

    /// What a pull request proposes as v1.3: a "tidy-up" that renames
    /// `merchant`, drops `office`, adds a required field and shrinks the
    /// input limit. Every change is a fleet outage; the linter says which.
    static let proposedV13: ContractRevision = {
        var revision = v12
        revision.version = ContractVersion(1, 3)
        revision.request.fields = revision.request.fields.map {
            $0.name == "text" ? Field("text", .string(maxLength: 4_000)) : $0
        }
        revision.response = ObjectSchema([
            Field("payee", .string(maxLength: 80)),
            Field("total", .number(0...1_000_000)),
            Field("category", .enumeration(cases: ["food", "travel", "other", "lodging", "hostel"], fallbacks: ["hostel": "lodging"])),
            Field("currency", .string(maxLength: 3), required: false),
            Field("confidence", .integer(0...100), required: false),
            Field("taxRate", .number(0...1)),
        ])
        return revision
    }()
}

// MARK: - Scripted models

enum ScriptedReceipts {
    /// Keyword "extraction" over the rendered prompt, shaped to whichever
    /// revision's schema it is asked for, so an older server answers in its
    /// own older shape. `variant` makes the on-device fixture disagree with
    /// the server fixture on exactly one receipt (ride-hailing).
    static func extract(_ prompt: String, _ schema: ObjectSchema, variant: Variant) -> ContractValue {
        let text = prompt.lowercased()
        let table: [(String, String, Double, String)] = [
            ("blue bottle", "Blue Bottle Coffee", 9.75, "food"),
            ("hilton", "Hilton Garden Inn", 412.40, "lodging"),
            ("uber", "Uber", 23.10, variant == .onDevice ? "other" : "travel"),
            ("staples", "Staples", 64.99, "office"),
            ("lufthansa", "Lufthansa", 1_288.00, "travel"),
        ]
        let match = table.first { text.contains($0.0) } ?? ("", "Unknown", 0, "other")
        var fields: [String: ContractValue] = [
            "merchant": .string(match.1), "total": .double(match.2),
            "category": .string(match.3), "currency": .string("USD"),
            "confidence": .int(variant == .server ? 93 : 78),
        ]
        if variant == .hallucinating { fields["category"] = .string("groceries") }
        // Answer only in the shape asked for: an old server's model gets an
        // old schema, and a category it does not know degrades to `travel`.
        if case .enumeration(let cases, _)? = schema.field(named: "category")?.type,
           case .string(let category)? = fields["category"], !cases.contains(category), variant != .hallucinating {
            fields["category"] = .string("travel")
        }
        let known = Set(schema.fields.map(\.name))
        return .object(fields.filter { known.contains($0.key) })
    }

    enum Variant: Sendable { case server, onDevice, hallucinating }

    static func onDevice(availability: ModelAvailability = .available, variant: Variant = .onDevice) -> ScriptedModel {
        ScriptedModel(name: "on-device (scripted)", availability: availability) { prompt, schema in
            extract(prompt, schema, variant: variant)
        }
    }

    static let server = ScriptedModel(name: "server model (scripted)") { prompt, schema in
        extract(prompt, schema, variant: .server)
    }
}

// MARK: - The scenario the console renders

enum DemoScenario {
    static let appShips = ContractVersion(1, 2)

    static func make() -> ConsoleScenario {
        let app = ReceiptContract.shared.asShipped(upTo: appShips)
        let policy = RoutingPolicy(onDeviceContextBudget: 1_024)

        func remote(serverShips: ContractVersion) -> ContractClient {
            let endpoint = ContractEndpoint(contracts: [ReceiptContract.shared.asShipped(upTo: serverShips)],
                                            model: ScriptedReceipts.server)
            return ContractClient(contract: app, transport: InProcessTransport(endpoint: endpoint))
        }
        func router(_ onDevice: ScriptedModel, server: ContractVersion = ContractVersion(1, 2),
                    residency: DataResidency = .serverAllowed) -> TierRouter {
            var contract = app
            contract.residency = residency
            return TierRouter(contract: contract, onDevice: onDevice, remote: remote(serverShips: server), policy: policy)
        }
        let noAI = ModelAvailability.unavailable(reason: "Apple Intelligence not enabled on this device")
        let folio = "Hilton Garden Inn — folio\n" + String(repeating: "Room night 189.00 · City tax 6.20 · Breakfast 18.00\n", count: 90)

        let routes = [
            RouteScenario(id: "short", title: "Coffee receipt", note: "Capable device, short prompt: answered on device, validated against v1.2.",
                          request: .object(["text": .string("BLUE BOTTLE COFFEE  Latte 5.25  Croissant 4.50  TOTAL 9.75")]),
                          router: router(ScriptedReceipts.onDevice())),
            RouteScenario(id: "noai", title: "No Apple Intelligence", note: "The on-device tier reports unavailable; the request crosses to the server.",
                          request: .object(["text": .string("STAPLES  Printer paper  TOTAL 64.99")]),
                          router: router(ScriptedReceipts.onDevice(availability: noAI))),
            RouteScenario(id: "long", title: "Nine-page hotel folio", note: "~1.25k tokens > the 1,024 on-device budget, so it skips straight to the server.",
                          request: .object(["text": .string(folio), "hint": .string("business")]),
                          router: router(ScriptedReceipts.onDevice())),
            RouteScenario(id: "invalid", title: "On-device answer fails the schema", note: "The device invents category \"groceries\". It is rejected, never shown, and the server answers.",
                          request: .object(["text": .string("BLUE BOTTLE COFFEE  TOTAL 9.75")]),
                          router: router(ScriptedReceipts.onDevice(variant: .hallucinating))),
            RouteScenario(id: "skew", title: "Server one deploy behind", note: "App ships v1.2, server api-2026.09 ships v1.1: the app resends at v1.1, then upgrades the answer.",
                          request: .object(["text": .string("HILTON GARDEN INN  2 nights  TOTAL 412.40")]),
                          router: router(ScriptedReceipts.onDevice(availability: noAI), server: ContractVersion(1, 1))),
            RouteScenario(id: "private", title: "Same failure, onDeviceOnly contract", note: "Residency is declared in the contract: an invalid on-device answer fails closed instead of sending the receipt off device.",
                          request: .object(["text": .string("BLUE BOTTLE COFFEE  TOTAL 9.75")]),
                          router: router(ScriptedReceipts.onDevice(variant: .hallucinating), residency: .onDeviceOnly)),
        ]

        let golden = ["Blue Bottle Coffee latte", "Hilton Garden Inn 2 nights", "Uber trip to SFO",
                      "Staples printer paper", "Lufthansa LH455 FRA-SFO"].enumerated().map { index, text in
            GoldenCase(id: "golden-\(index + 1): \(text)", request: .object(["text": .string(text)]))
        }

        return ConsoleScenario(
            contract: ReceiptContract.shared,
            proposed: ReceiptContract.proposedV13,
            apps: [
                AppBuild(name: "App 3.8", shipped: ContractVersion(1, 0), installBasisPoints: 600),
                AppBuild(name: "App 4.0", shipped: ContractVersion(1, 1), installBasisPoints: 3_100),
                AppBuild(name: "App 4.1", shipped: ContractVersion(1, 2), installBasisPoints: 6_300),
            ],
            servers: [
                ServerBuild(name: "api-2026.09", shipped: ContractVersion(1, 1)),
                ServerBuild(name: "api-2026.10", shipped: ContractVersion(1, 2)),
                ServerBuild(name: "api-2026.11 (plan)", shipped: ContractVersion(1, 2), retiredBelow: ContractVersion(1, 1)),
            ],
            routes: routes,
            golden: golden,
            parity: ParityEval(revision: ReceiptContract.v12,
                               rules: ["merchant": .normalizedText, "total": .tolerance(0.01), "confidence": .ignore],
                               thresholdBasisPoints: 9_000),
            reference: ScriptedReceipts.server,
            candidate: ScriptedReceipts.onDevice())
    }
}
