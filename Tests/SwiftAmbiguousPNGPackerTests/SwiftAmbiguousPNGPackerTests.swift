import XCTest
@testable import SwiftAmbiguousPNGPacker

final class SwiftAmbiguousPNGPackerTests: XCTestCase {

    func testFixtures() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.

        let appleImageURL = Bundle.module.url(forResource: "Fixtures/mac_hello_240p", withExtension: "png")!
        let otherImageURL = Bundle.module.url(forResource: "Fixtures/ibm_pc_240p", withExtension: "png")!
        let desiredOutputURL = Bundle.module.url(forResource: "Fixtures/mac_vs_ibm_output", withExtension: "png")!
        let desiredData = try Data(contentsOf: desiredOutputURL)

        let outputURL = try FileManager.default.url(
            for: .itemReplacementDirectory,
               in: .userDomainMask,
               appropriateFor: appleImageURL,
               create: true
        ).appendingPathComponent("output.png")
        try SwiftAmbiguousPNGPacker().pack(
            appleImageURL: appleImageURL,
            otherImageURL: otherImageURL,
            outputURL: outputURL
        )
        let outputData = try Data(contentsOf: outputURL)
        XCTAssert(desiredData == outputData)
    }
}
