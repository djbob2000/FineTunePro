// FineTuneTests/LocalizationResourceTests.swift
// Verifies that app-bundle localization resources are present and usable.

import Foundation
import Testing
@testable import FineTune

@Suite("Localization resources")
struct LocalizationResourceTests {
    // Mirrors Apple's 50 App Store localization languages for the app binary.
    // Norwegian uses the Foundation/Xcode bundle identifier `nb` rather than
    // the App Store Connect metadata shortcode `no`.
    private static let mainstreamLocaleIdentifiers: [String] = [
        "ar-SA",
        "bn-BD",
        "ca",
        "zh-Hans",
        "zh-Hant",
        "hr",
        "cs",
        "da",
        "nl-NL",
        "en-AU",
        "en-CA",
        "en-GB",
        "en-US",
        "fi",
        "fr-FR",
        "fr-CA",
        "de-DE",
        "el",
        "gu-IN",
        "he",
        "hi",
        "hu",
        "id",
        "it",
        "ja",
        "kn-IN",
        "ko",
        "ms",
        "ml-IN",
        "mr-IN",
        "nb",
        "or-IN",
        "pl",
        "pt-BR",
        "pt-PT",
        "pa-IN",
        "ro",
        "ru",
        "sk",
        "sl-SI",
        "es-MX",
        "es-ES",
        "sv",
        "ta-IN",
        "te-IN",
        "th",
        "tr",
        "uk",
        "ur-PK",
        "vi",
    ]

    // New upstream copy has verified Chinese/Portuguese translations. Other locales
    // intentionally fall back to English until translated; prior coverage stays required.
    private static let pendingTranslationKeys: Set<String> = [
        "Apps",
        "Change icon",
        "Computers & Displays",
        "Connection timed out",
        "Connectors & Other",
        "Couldn't connect",
        "Device",
        "Failed to fetch catalog",
        "Headphones & Earbuds",
        "In exclusive use by %@ (PID %@)",
        "In exclusive use by PID %@",
        "Invalid catalog data",
        "Lower volume for the app playing audio",
        "Microphones",
        "Network error: %@",
        "No matching icons",
        "Restore Default",
        "Search icons",
        "Speakers",
        "Suggested",
        "Play this app in mono"
    ]

    private struct StringCatalog: Decodable {
        struct Entry: Decodable {
            struct Localization: Decodable {
                struct StringUnit: Decodable {
                    let value: String
                }

                let stringUnit: StringUnit?
                let variations: [String: [String: Localization]]?

                var values: [String] {
                    if let stringUnit { return [stringUnit.value] }
                    return (variations ?? [:]).values.flatMap { $0.values.flatMap(\.values) }
                }
            }

            let localizations: [String: Localization]?
        }

        let strings: [String: Entry]
    }

    @Test("app bundle includes all mainstream localizations")
    func appBundleIncludesAllMainstreamLocalizations() {
        let localizedRegions = Set(Bundle.main.localizations)

        for localeIdentifier in Self.mainstreamLocaleIdentifiers {
            #expect(localizedRegions.contains(localeIdentifier))
        }
        #expect(!localizedRegions.contains("no"))
    }

    @Test("string catalogs include complete translations for every mainstream localization")
    func stringCatalogsIncludeCompleteTranslationsForEveryMainstreamLocalization() throws {
        let catalogURLs = [
            sourceRoot().appending(path: "FineTune/Localizable.xcstrings"),
            sourceRoot().appending(path: "FineTune/InfoPlist.xcstrings"),
        ]

        for catalogURL in catalogURLs {
            let data = try Data(contentsOf: catalogURL)
            let catalog = try JSONDecoder().decode(StringCatalog.self, from: data)
            let expectedLocaleIdentifiers = Set(Self.mainstreamLocaleIdentifiers)
            let actualLocaleIdentifiers = Set(catalog.strings.values.flatMap { entry in
                Array((entry.localizations ?? [:]).keys)
            })
            #expect(actualLocaleIdentifiers.subtracting(["en"]) == expectedLocaleIdentifiers)

            for (key, entry) in catalog.strings {
                let localizations = entry.localizations ?? [:]
                for localeIdentifier in Self.mainstreamLocaleIdentifiers {
                    if Self.pendingTranslationKeys.contains(key), !["zh-Hans", "pt-BR"].contains(localeIdentifier), localizations[localeIdentifier] == nil { continue }
                    let values = localizations[localeIdentifier]?.values ?? []
                    #expect(!values.isEmpty, "Missing translation for \(key) in \(localeIdentifier)")
                    for value in values {
                        #expect(!value.isEmpty)
                        #expect(Self.formatSpecifiers(in: value) == Self.formatSpecifiers(in: key))
                    }
                }
            }
        }
    }

    @Test("InfoPlist localizations contain user-facing permission copy")
    func infoPlistLocalizationsContainUserFacingPermissionCopy() throws {
        let catalogURL = sourceRoot().appending(path: "FineTune/InfoPlist.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let catalog = try JSONDecoder().decode(StringCatalog.self, from: data)
        let permissionKeys = [
            "NSAudioCaptureUsageDescription",
            "NSBluetoothAlwaysUsageDescription",
            "NSMicrophoneUsageDescription",
        ]

        for localeIdentifier in Self.mainstreamLocaleIdentifiers {
            let bundleName = catalog.strings["CFBundleName"]?.localizations?[localeIdentifier]?.stringUnit?.value
            #expect(bundleName == "FineTune")

            for key in permissionKeys {
                let value = catalog.strings[key]?.localizations?[localeIdentifier]?.stringUnit?.value ?? ""
                #expect(value != key)
                #expect(value.contains("FineTune"))
            }
        }
    }

    private func sourceRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func formatSpecifiers(in string: String) -> [String] {
        let pattern = #"%(?:[0-9]+\$)?(?:ll|l)?[@dfiouxX]|%%"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.matches(in: string, range: range).map { match in
            String(string[Range(match.range, in: string)!]).replacingOccurrences(of: #"[0-9]+\$"#, with: "", options: .regularExpression)
        }.sorted()
    }

    @Test("Upstream additions localize runtime strings and mono help", arguments: ["zh-Hans", "pt-BR"])
    func upstreamRuntimeStrings(locale: String) throws {
        let path = try #require(Bundle.main.path(forResource: locale, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        for key in ["Connection timed out", "Couldn't connect", "Failed to fetch catalog", "Computers & Displays", "Play this app in mono"] {
            #expect(L10n.string(key, bundle: bundle) != key)
        }
        let hog = try #require(DeviceInspectorInfo.formatHogModeOwner(123456, processName: "Example", bundle: bundle))
        #expect(hog.contains("Example"))
        #expect(hog.contains("123456"))
        #expect(!hog.hasPrefix("In exclusive use"))
    }

    @Test("Simplified Chinese resources localize core UI strings")
    func simplifiedChineseResourcesLocalizeCoreUIStrings() throws {
        let appBundle = Bundle.main
        #expect(appBundle.localizations.contains("zh-Hans"))

        let zhPath = try #require(appBundle.path(forResource: "zh-Hans", ofType: "lproj"))
        let zhBundle = try #require(Bundle(path: zhPath))

        #expect(zhBundle.localizedString(forKey: "Settings", value: nil, table: nil) == "设置")
        #expect(zhBundle.localizedString(forKey: "General", value: nil, table: nil) == "通用")
        #expect(zhBundle.localizedString(forKey: "Audio", value: nil, table: nil) == "音频")
    }
}
