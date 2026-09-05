import Foundation
import Testing
@testable import Oriveo

@Suite("Relay Setup Localization")
struct RelaySetupLocalizationTests {
    private let supportedLocales: Set<String> = [
        "ar", "de", "en", "es", "fr", "hi", "id", "ja",
        "ko", "pt-BR", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant",
    ]

    private let providersKeys: Set<String> = [
        "%d compatible protocol(s) will be tested automatically.",
        "Automatic (Recommended)",
        "Automatic protocol testing failed: %@",
        "Basic Settings",
        "Catalog detection is not enough. Automatic testing sends at most 1 token through the real chat path and selects a working protocol for you.",
        "Catalog found, but it returned no model IDs. Enter a model above to continue.",
        "Add Custom Relay",
        "Choose a protocol manually",
        "Clear learned capabilities",
        "Confirmed the %@ protocol, but this relay does not publish a model catalog. Enter a model ID above to continue.",
        "Connect a relay",
        "Connect a relay or local engine",
        "Connect and save",
        "Connection has not been verified.",
        "Connection settings",
        "Could not detect this relay",
        "Custom Relay",
        "Detect connection settings",
        "Detect settings",
        "Detecting...",
        "Detection failed",
        "Discovered from relay catalog",
        "Edit • %@",
        "Edit Relay Settings",
        "Enter the API address provided by your relay.",
        "Enter the access token required by this engine.",
        "Enter a request URL.",
        "Enter a valid HTTPS request URL.",
        "Enter the request URL and API key. Oriveo will detect the connection settings for you.",
        "Enter what your relay gave you. Oriveo will detect the API root, authentication style, and compatible protocol.",
        "Found %d model(s) in the catalog.",
        "Hide API key",
        "Image generation is not available on this transport. Open Providers → this Relay → Advanced Settings → Transport and switch it to OpenAI Responses or Chat Completions.",
        "Invalid request URL",
        "Manual setup",
        "Local compute",
        "Model catalog found",
        "Neither a model catalog nor a known generation endpoint answered at this address. Check the address, or choose the protocol manually.",
        "No detected protocol completed the test request.",
        "No supported relay configuration was detected.",
        "Opens manual connection settings",
        "Paste the host, /v1 or /v1beta base URL, or a full API route. Oriveo will normalize it safely.",
        "Please add a chat model to this relay before using image generation.",
        "Quick Setup",
        "Recommended. Used when the relay does not return a model list.",
        "Remove query parameters from the request URL. Oriveo never tries API keys from query parameters automatically.",
        "Request URL",
        "Retried %d time(s) automatically.",
        "Relay",
        "Remove stored key",
        "Saving sends one tiny test request to confirm the new key works.",
        "Save and continue",
        "Show API key",
        "Test protocols automatically",
        "Testing protocols...",
        "The actual chat path is verified. You can save this relay now.",
        "The local network is unavailable.",
        "This engine requires an encrypted connection for its access token.",
        "The catalog cannot distinguish these OpenAI-compatible protocols. You do not need to guess—use automatic testing below and Oriveo will select one that completes a real request.",
        "The relay answered, but its model catalog format was not recognized.",
        "The relay could not be reached reliably. Check the address and try again.",
        "The server did not return an HTTP response.",
        "The relay is rate limited. Wait and try again; Oriveo did not rotate credentials or protocols.",
        "The server rejected the API key. Check the key or choose the documented protocol manually.",
        "Verified %@ through the actual chat path.",
        "Verified through the actual chat path",
        "Verifying the new key…",
        "What Oriveo tried",
        "Use only if automatic detection fails.",
        "Use an HTTPS request URL. Local-network and VPN addresses are supported when they use a valid TLS certificate.",
        "Use your own request URL and API key",
        "Your API key is stored securely on this device and is sent only to your relay.",
    ]

    @Test("Relay setup copy has real translations for every supported locale")
    func relaySetupCopyCoversEveryLocale() throws {
        try assertCatalog("Providers", contains: providersKeys)
    }

    @Test("Custom LLM-only settings copy explicitly uses the Providers table")
    func customLLMSettingsCopyUsesProvidersTableAtEveryConsumer() throws {
        let httpsCall = "L10n.tr(RelayEndpointPolicy.httpsRequiredMessageKey, table: .providers)"
        let expectedHTTPSCallCounts = [
            "Oriveo/Features/Providers/RelaySetupView.swift": 3,
            "Oriveo/Features/Providers/RelayEditView.swift": 3,
            "Oriveo/Features/Providers/LocalComputeSetupView.swift": 1,
        ]
        for (relativePath, expectedCount) in expectedHTTPSCallCounts {
            let source = try String(
                contentsOf: projectRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            #expect(source.components(separatedBy: httpsCall).count - 1 == expectedCount)
            #expect(!source.contains("L10n.tr(RelayEndpointPolicy.httpsRequiredMessageKey)"))
        }

        let sheet = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/GenerationParameterDefaultsSheet.swift"),
            encoding: .utf8
        )
        #expect(sheet.contains("L10n.tr(\"Basic Settings\", table: .providers)"))
        #expect(!sheet.contains("L10n.tr(\"Basic Settings\")"))
    }

    @Test("Image-generation relay errors use Providers and match the Web production catalog")
    func imageGenerationErrorsUseProvidersAndMatchWebProductionValues() throws {
        let routeKey = "Image generation is not available on this transport. Open Providers → this Relay → Advanced Settings → Transport and switch it to OpenAI Responses or Chat Completions."
        let modelKey = "Please add a chat model to this relay before using image generation."
        let providers = try catalogValues(table: "Providers")
        let routeValues = try #require(providers[routeKey])
        let modelValues = try #require(providers[modelKey])
        #expect(Set(routeValues.keys) == supportedLocales)
        #expect(Set(modelValues.keys) == supportedLocales)

        for locale in supportedLocales {
            let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(
                "web/apps/app/messages/\(locale).json"
            ))
            let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let errors = try #require(root["errors"] as? [String: Any])
            let relay = try #require(errors["relay"] as? [String: Any])
            let webValue = try #require(relay["imageRouteUnsupported"] as? String)
            #expect(routeValues[locale] == webValue, "image route copy drifted for \(locale)")
        }

        let chatManager = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Core/State/ChatManager.swift"),
            encoding: .utf8
        )
        #expect(chatManager.contains("L10n.tr(\"\(routeKey)\", table: .providers)"))
        #expect(chatManager.contains("L10n.tr(\"\(modelKey)\", table: .providers)"))
        #expect(!chatManager.contains("L10n.tr(\"\(routeKey)\", table: .chat)"))
        #expect(!chatManager.contains("L10n.tr(\"\(modelKey)\", table: .chat)"))
    }

    @Test("Custom Relay Copy Uses Production Catalog Values")
    func customRelayCopyUsesProductionCatalogValues() throws {
        let providers = try catalogValues(table: "Providers")
        #expect(providers["Custom Relay"]?["en"] == "Custom Relay")
        #expect(providers["Connect a relay"]?["en"] == "Connect a custom relay")
        #expect(providers["Connect a relay"]?.values.allSatisfy { !$0.localizedCaseInsensitiveContains("LLM") } == true)
        #expect(providers["Add Custom Relay"]?["en"] == "Add Custom Relay")
        #expect(providers["Connect a relay or local engine"]?["en"] == "Connect your own model service, or local & LAN compute")
        #expect(providers["Edit Relay Settings"]?["en"] == "Connection settings")
        #expect(providers["Relay"]?["en"] == "Relay service")
        #expect(providers["Connection security"]?["en"] == "Connection security")
        #expect(providers["Local compute"]?["en"] == "Local & LAN compute")
        #expect(providers["Custom Relay"]?["zh-Hans"] != "Custom Relay")

        let edit = try String(contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/RelayEditView.swift"), encoding: .utf8)
        #expect(edit.contains("L10n.tr(\"Edit • %@\", table: .providers)"))
        #expect(!edit.contains("L10n.tr(\"Edit Relay\", table: .providers)"))
    }

    @Test("Connection field terminology follows the 16-locale iOS golden matrix")
    func connectionFieldTerminologyMatchesGoldenMatrix() throws {
        let providers = try catalogValues(table: "Providers")
        #expect(providers["Protocol"]?["en"] == "Protocol")
        #expect(providers["Transport"]?["en"] == "Protocol")
        #expect(providers["Auth Mode"]?["en"] == "Authentication")
        #expect(providers["Request URL"]?["en"] == "Request URL")
        #expect(providers["Base URL"]?["en"] == "Request URL")
        #expect(providers["Relay type"]?["en"] == "Protocol type")
        #expect(providers["Compatibility"]?["en"] == "Compatibility")
        #expect(providers["Request Behavior"]?["en"] == "Compatibility")
        #expect(providers["Model"]?["en"] == "Model")
        #expect(providers["Advanced HTTP"]?["en"] == "Advanced HTTP")
        #expect(providers["Relay"]?["en"] == "Relay service")
        for key in ["Protocol", "Auth Mode", "Request URL", "Model", "Relay"] {
            let values = try #require(providers[key])
            #expect(Set(values.keys) == supportedLocales)
            #expect(values["zh-Hans"] != values["en"])
        }
    }

    @Test("Relay Key Rotation Copy Is Localized And Wired Into The Sheet")
    func relayKeyRotationCopyIsLocalizedAndWiredIntoTheSheet() throws {
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/ProviderSettingsSection.swift"),
            encoding: .utf8
        )

        #expect(source.contains("provider?.kind == .relay"))
        #expect(source.contains("Saving sends one tiny test request to confirm the new key works."))
        #expect(source.contains("Verifying the new key…"))
    }

    @Test("Provider Issue Message Has No Table Drift At Consumers")
    func providerIssueMessageHasNoTableDriftAtConsumers() throws {
        for relativePath in [
            "Oriveo/Features/Providers/ProviderDetailView.swift",
            "Oriveo/Features/Providers/ProviderSetupView.swift",
        ] {
            let source = try String(contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8)
            #expect(source.contains("ProviderIssueMessage.localized"), "\(relativePath) bypasses ProviderIssueMessage")
        }
        let detail = try String(contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/ProviderDetailView.swift"), encoding: .utf8)
        #expect(detail.components(separatedBy: "ProviderIssueMessage.localized").count >= 3)
    }

    @Test("Relay Edit Immediate Failure Uses The Default Table")
    func relayEditImmediateFailureUsesTheDefaultTable() throws {
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/RelayEditView.swift"),
            encoding: .utf8
        )
        let key = "We couldn't verify the connection. You can retry from the provider details."
        #expect(source.components(separatedBy: "L10n.tr(\"\(key)\")").count - 1 == 3)
        #expect(!source.contains("L10n.tr(\"\(key)\", table: .providers)"))
    }

    @Test("Relay setup user-facing copy no longer calls the request URL Endpoint")
    func requestURLTerminologyIsConsistent() throws {
        let bannedTerms = [
            "L10n.tr(\"Endpoint\"",
            "Endpoint is empty.",
            "Invalid endpoint",
            "Enter a valid HTTPS endpoint.",
            "from the Endpoint",
        ]

        for relativePath in [
            "Oriveo/Features/Providers/RelaySetupView.swift",
            "Oriveo/Features/Providers/RelaySimpleSection.swift",
            "Oriveo/Features/Providers/RelayEditView.swift",
            "Oriveo/Features/Providers/RelayConnectionCard.swift",
            "Oriveo/Features/Providers/RelayAdvancedFieldsView.swift",
        ] {
            let source = try String(contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8)
            for bannedTerm in bannedTerms {
                #expect(!source.contains(bannedTerm), "\(relativePath) still contains \(bannedTerm)")
            }
        }
    }

    @Test("Default Model Placeholder Is A Real Model ID")
    func defaultModelPlaceholderIsARealModelID() throws {
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/RelaySimpleSection.swift"),
            encoding: .utf8
        )
        #expect(!source.contains("Enter a model ID"))

        for candidate in [RelayModelPlaceholder.fallback, RelayModelPlaceholder.current] {
            #expect(!candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!candidate.contains(" "))
            #expect(candidate.rangeOfCharacter(from: .decimalDigits) != nil)
        }
    }

    @Test("Discovered Catalog Drives The Default Model Field")
    func discoveredCatalogDrivesTheDefaultModelField() throws {
        let section = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/RelaySimpleSection.swift"),
            encoding: .utf8
        )
        #expect(section.contains("if discoveredModelIDs.isEmpty {"))
        #expect(section.contains("RelayDiscoveredModelField("))

        let setup = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/RelaySetupView.swift"),
            encoding: .utf8
        )
        #expect(setup.contains("guard !discoveredModelIDs.contains(trimmed) else { return }"))
        #expect(setup.contains("defaultModelID = firstDiscovered"))
    }

    @Test("Empty Catalog Still Has An Exit")
    func emptyCatalogStillHasAnExit() throws {
        let setup = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/RelaySetupView.swift"),
            encoding: .utf8
        )
        #expect(setup.contains("} else if needsDefaultModelInput {"))
        #expect(setup.contains("await saveDetectedRelay(verified: false)"))
        #expect(setup.contains("if needsDefaultModelInput { return L10n.tr(\"Save and continue\""))
        #expect(setup.contains(": .issue(L10n.tr(\"Connection has not been verified.\""))
        #expect(setup.contains("context: .onboarding"))
    }

    @Test("Relay Edit Persists Unverified Stable Key")
    func relayEditPersistsUnverifiedStableKey() throws {
        let edit = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/RelayEditView.swift"),
            encoding: .utf8
        )
        #expect(edit.contains("transitioning.status = .issue(ProviderIssueMessage.unverifiedConnectionKey)"))
        #expect(edit.contains("updated.lastError = ProviderIssueMessage.unverifiedConnectionKey"))
        #expect(!edit.contains("transitioning.status = .issue(L10n.tr(\"Connection has not been verified.\""))
    }

    @Test("Relay Key Rotation Uses Shared Failure Presentation")
    func relayKeyRotationUsesSharedFailurePresentation() throws {
        let settings = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/ProviderSettingsSection.swift"),
            encoding: .utf8
        )
        #expect(settings.contains("RelayEditFailurePresentation.error("))
        #expect(settings.contains("actionTitle: L10n.tr(\"OK\")"))
    }

    @Test("Relay Catalog Is Reachable From The Detail Page")
    func relayCatalogIsReachableFromTheDetailPage() throws {
        let detail = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/ProviderDetailView.swift"),
            encoding: .utf8
        )
        #expect(detail.contains("return provider.kind == .relay"))
        #expect(detail.contains("!provider.catalogModels.isEmpty"))

        let setup = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/RelaySetupView.swift"),
            encoding: .utf8
        )
        #expect(setup.contains("let catalogIDs = await discoveredCatalogIDs("))
        #expect(setup.contains("catalogModelIDs: catalogIDs"))
    }

    private func assertCatalog(_ table: String, contains keys: Set<String>) throws {
        let data = try Data(contentsOf: projectRoot.appendingPathComponent("Oriveo/\(table).xcstrings"))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])

        for key in keys {
            let entry = try #require(strings[key] as? [String: Any], "\(table) is missing \(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            #expect(Set(localizations.keys) == supportedLocales, "\(table)/\(key) has incomplete locale coverage")

            let english = try localizedValue(locale: "en", localizations: localizations, key: key)
            let expectedPlaceholders = placeholders(in: english)
            for locale in supportedLocales {
                let value = try localizedValue(locale: locale, localizations: localizations, key: key)
                #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #expect(placeholders(in: value) == expectedPlaceholders, "\(table)/\(key)/\(locale) changed format placeholders")
                if locale != "en" {
                    #expect(value != english, "\(table)/\(key)/\(locale) still falls back to English")
                }
            }
        }
    }

    private func catalogValues(table: String) throws -> [String: [String: String]] {
        let data = try Data(contentsOf: projectRoot.appendingPathComponent("Oriveo/\(table).xcstrings"))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        return try strings.reduce(into: [:]) { result, item in
            let localizations = try #require((item.value as? [String: Any])?["localizations"] as? [String: Any])
            result[item.key] = try localizations.reduce(into: [:]) { values, locale in
                let unit = try #require((locale.value as? [String: Any])?["stringUnit"] as? [String: Any])
                values[locale.key] = try #require(unit["value"] as? String)
            }
        }
    }

    private func localizedValue(
        locale: String,
        localizations: [String: Any],
        key: String
    ) throws -> String {
        let localeEntry = try #require(localizations[locale] as? [String: Any], "Missing \(locale) for \(key)")
        let stringUnit = try #require(localeEntry["stringUnit"] as? [String: Any])
        #expect(stringUnit["state"] as? String == "translated")
        return try #require(stringUnit["value"] as? String)
    }

    private func placeholders(in value: String) -> [String] {
        let pattern = #"%(?:\d+\$)?(?:lld|ld|d|@)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: value) else { return nil }
            return value[swiftRange].replacingOccurrences(
                of: #"%\d+\$"#,
                with: "%",
                options: .regularExpression
            )
        }.sorted()
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var repositoryRoot: URL {
        projectRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
