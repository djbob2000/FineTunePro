# Parametric EQ Optional Q Fallback Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Allow importing Parametric EQ configurations where shelf/peaking filters omit the `Q` parameter by falling back to standard default Q values (0.707 for shelf filters, 1.0 for peaking filters) instead of skipping them.

**Architecture:** Update the filter line parsing logic in `AutoEQParser.swift` to extract `frequency` and `gainDB` as required, but treat `Q` as optional. If `Q` is not specified, assign a type-dependent default value (`0.707` for `.lowShelf` and `.highShelf`, `1.0` for `.peaking`) and validate. Create new unit tests in `AutoEQParserTests.swift` to ensure correctness and prevent regressions.

**Tech Stack:** Swift, Xcode testing

---

### Task 1: Create Unit Tests for Optional Q Parser Logic

**Files:**
- Create: [AutoEQParserTests.swift](file:///Users/air/develop/FineTuneFork/FineTuneTests/AutoEQParserTests.swift)

**Step 1: Write the failing tests**
Create `FineTuneTests/AutoEQParserTests.swift` with tests checking that:
1. Filters with missing Q default correctly depending on type.
2. Filters with explicit Q are parsed with their explicit Q values.

```swift
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
        #expect(profile != nil)
        
        let filters = profile!.filters
        #expect(filters.count == 10)
        
        // Filter 1: PK with explicit Q
        #expect(filters[0].type == .peaking)
        #expect(filters[0].frequency == 17)
        #expect(filters[0].gainDB == 0.2)
        #expect(filters[0].q == 0.8)
        
        // Filter 2: LS with missing Q -> defaults to 0.707
        #expect(filters[1].type == .lowShelf)
        #expect(filters[1].frequency == 105)
        #expect(filters[1].gainDB == 6.0)
        #expect(filters[1].q == 0.707)
        
        // Filter 5: HS with missing Q -> defaults to 0.707
        #expect(filters[4].type == .highShelf)
        #expect(filters[4].frequency == 1300)
        #expect(filters[4].gainDB == 6.5)
        #expect(filters[4].q == 0.707)
        
        // Filter 10: HS with missing Q -> defaults to 0.707
        #expect(filters[9].type == .highShelf)
        #expect(filters[9].frequency == 11000)
        #expect(filters[9].gainDB == 8.2)
        #expect(filters[9].q == 0.707)
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
```

**Step 2: Run test to verify it fails**
Run the newly created tests to ensure they fail or fail to compile because the parser does not support optional Q yet.
Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests/AutoEQParserTests CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO`
Expected: FAIL (compiles, but tests fail or parser returns nil/skips filters)

---

### Task 2: Implement Optional Q Parsing Logic in AutoEQParser

**Files:**
- Modify: [AutoEQParser.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/AutoEQ/AutoEQParser.swift)

**Step 1: Modify parseFilterLine to allow optional Q**
Modify `parseFilterLine` in [AutoEQParser.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/AutoEQ/AutoEQParser.swift) to parse frequency and gain first, then look for Q. If Q is missing, fall back to default values based on the filter type.

Replace:
```swift
        // Extract Fc (frequency), Gain, Q
        guard let frequency = extractValue(after: "Fc", in: tokens),
              let gainDB = extractValue(after: "Gain", in: tokens),
              let q = extractValue(after: "Q", in: tokens) else {
            return nil
        }

        // Validate ranges
        guard frequency > 0, q > 0, abs(gainDB) <= 30 else { return nil }
```

With:
```swift
        // Extract Fc (frequency), Gain
        guard let frequency = extractValue(after: "Fc", in: tokens),
              let gainDB = extractValue(after: "Gain", in: tokens) else {
            return nil
        }

        // Extract Q or fall back to default based on type
        let q: Float
        if let parsedQ = extractValue(after: "Q", in: tokens) {
            q = parsedQ
        } else {
            switch type {
            case .peaking:
                q = 1.0
            case .lowShelf, .highShelf:
                q = 0.707
            }
        }

        // Validate ranges
        guard frequency > 0, q > 0, abs(gainDB) <= 30 else { return nil }
```

**Step 2: Run tests to verify they pass**
Run the tests to verify the new parser logic works correctly.
Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests/AutoEQParserTests CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO`
Expected: PASS

**Step 3: Run the full unit test suite**
Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO`
Expected: PASS
