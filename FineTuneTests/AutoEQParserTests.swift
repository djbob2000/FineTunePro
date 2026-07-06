// FineTuneTests/AutoEQParserTests.swift
import Testing
import Foundation
@testable import FineTune

@Suite("AutoEQParser Tests")
struct AutoEQParserTests {

    @Test("Parse parametric EQ with missing Q parameter for shelf filters")
    func parseParametricEQMissingQShelf() {
        let text = """
Preamp: -5 dB
Filter 1: ON PK Fc 17 Hz Gain 0.2 dB Q 0.8
Filter 2: ON LS Fc 105 Hz Gain 6 dB
Filter 3: ON PK Fc 210 Hz Gain -1.5 dB Q 1.5
Filter 4: ON PK Fc 1200 Hz Gain -2.4 dB Q 1.4
Filter 5: ON HS Fc 1300 Hz Gain 6.5 dB
Filter 6: ON PK Fc 2900 Hz Gain -0.8 dB Q 5
Filter 7: ON PK Fc 4920 Hz Gain -2.5 dB Q 6
Filter 8: ON PK Fc 6300 Hz Gain -1 dB Q 6
Filter 9: ON PK Fc 8450 Hz Gain -2 dB Q 7
Filter 10: ON HS Fc 11000 Hz Gain 8.2 dB
"""
        let profile = AutoEQParser.parse(text: text, name: "Test Headphone", source: .imported)
        var log = ""
        log += "profile is \(profile == nil ? "nil" : "non-nil")\n"
        if let profile = profile {
            log += "filters count = \(profile.filters.count)\n"
            for (index, f) in profile.filters.enumerated() {
                log += "Filter \(index + 1): type=\(f.type) Fc=\(f.frequency) Gain=\(f.gainDB) Q=\(f.q)\n"
            }
        }
        
        do {
            try log.write(toFile: "/Users/air/.gemini/antigravity-ide/brain/e1c028fd-1c29-476f-8d01-c649df00813d/test_output.txt", atomically: true, encoding: .utf8)
        } catch {
            print("Failed to write test output file")
        }

        #expect(profile != nil)
        
        let filters = profile!.filters
        #expect(filters.count == 10)
        
        // Filter 1: PK with explicit Q
        #expect(filters[0].type == .peaking)
        #expect(filters[0].frequency == 17)
        #expect(abs(filters[0].gainDB - 0.2) < 1e-5)
        #expect(abs(filters[0].q - 0.8) < 1e-5)
        
        // Filter 2: LS with missing Q -> defaults to 0.707
        #expect(filters[1].type == .lowShelf)
        #expect(filters[1].frequency == 105)
        #expect(abs(filters[1].gainDB - 6.0) < 1e-5)
        #expect(abs(filters[1].q - 0.707) < 1e-5)
        
        // Filter 5: HS with missing Q -> defaults to 0.707
        #expect(filters[4].type == .highShelf)
        #expect(filters[4].frequency == 1300)
        #expect(abs(filters[4].gainDB - 6.5) < 1e-5)
        #expect(abs(filters[4].q - 0.707) < 1e-5)
        
        // Filter 10: HS with missing Q -> defaults to 0.707
        #expect(filters[9].type == .highShelf)
        #expect(filters[9].frequency == 11000)
        #expect(abs(filters[9].gainDB - 8.2) < 1e-5)
        #expect(abs(filters[9].q - 0.707) < 1e-5)
    }

    @Test("Parse parametric EQ with missing Q parameter for peaking filters")
    func parseParametricEQMissingQPeaking() {
        let text = """
Filter 1: ON PK Fc 1000 Hz Gain 3.0 dB
"""
        let profile = AutoEQParser.parse(text: text, name: "Test Headphone 2", source: .imported)
        #expect(profile != nil)
        #expect(profile!.filters.count == 1)
        #expect(profile!.filters[0].type == .peaking)
        #expect(profile!.filters[0].q == 1.0)
    }
}
