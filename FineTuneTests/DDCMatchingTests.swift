// FineTuneTests/DDCMatchingTests.swift
// Tests for DDC display matching algorithms (Issue #381)

#if !APP_STORE

import Testing
@testable import FineTune

@Suite("DDCController — Display Matching Tests")
struct DDCMatchingTests {

    @Test("EDID vendor and product matching against CoreAudio device UID prefix")
    func testEDIDMatchesUIDPrefix() {
        // Vendor 0x1E6D, Product 0x5077
        // Product 0x5077 byte swapped is 0x7750 -> prefix "1e6d7750"
        let uid = "1e6d7750-0000-0000-071f-010080210300"
        
        let edid = DDCController.DisplayEDID(
            vendorID: 0x1E6D,
            productID: 0x5077,
            serialNumber: 0x071F
        )

        let matches = DDCController.edidMatchesUID(edid, uid: uid)
        #expect(matches == true)
    }

    @Test("EDID matching with serial number disambiguates identical monitors")
    func testEDIDMatchesUIDWithSerial() {
        let uidMonitorA = "1e6d7750-0000-0000-071f-000000000000"
        let uidMonitorB = "1e6d7750-0000-0000-0720-000000000000"

        let edidA = DDCController.DisplayEDID(
            vendorID: 0x1E6D,
            productID: 0x5077,
            serialNumber: 0x071F
        )

        let edidB = DDCController.DisplayEDID(
            vendorID: 0x1E6D,
            productID: 0x5077,
            serialNumber: 0x0720
        )

        let matchA_A = DDCController.edidMatchesUIDWithSerial(edidA, uid: uidMonitorA)
        let matchA_B = DDCController.edidMatchesUIDWithSerial(edidA, uid: uidMonitorB)
        let matchB_B = DDCController.edidMatchesUIDWithSerial(edidB, uid: uidMonitorB)

        #expect(matchA_A == true)
        #expect(matchA_B == false)
        #expect(matchB_B == true)
    }
}

#endif
