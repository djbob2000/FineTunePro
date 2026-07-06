// FineTuneTests/LiquidGlassTests.swift
import Testing
import SwiftUI
@testable import FineTune

@Suite("Liquid Glass Design Extensions")
struct LiquidGlassTests {
    @Test("Custom glass view modifiers compile and return valid views")
    @MainActor
    func testGlassModifiers() {
        let text = Text("Test View")
        
        let darkGlass = text.darkGlassBackground()
        #expect(darkGlass != nil)
        
        let glassStyleView = text.glassStyle()
        #expect(glassStyleView != nil)
        
        let menuGlassView = text.menuGlassStyle()
        #expect(menuGlassView != nil)
    }
}
