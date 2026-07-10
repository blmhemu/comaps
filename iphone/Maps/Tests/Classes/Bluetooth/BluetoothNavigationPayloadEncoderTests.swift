import Foundation
import XCTest
@testable import CoMaps__Debug_

final class BluetoothNavigationPayloadEncoderTests: XCTestCase {
  func testEncodingMatchesRadarWireFormat() throws {
    let update = BluetoothNavigationUpdate(sequence: 300,
                                           state: .active,
                                           maneuver: .turnLeft,
                                           distanceMeters: 150,
                                           etaSeconds: 20,
                                           primary: "Go",
                                           secondary: "A")

    let payload = try XCTUnwrap(RadarNavigationPayloadEncoder.encode(update,
                                                                    maxPayloadBytes: 106,
                                                                    maxTextBytes: 40))

    XCTAssertEqual(payload, Data([0x08, 0xAC, 0x02,
                                  0x10, 0x02,
                                  0x18, 0x03,
                                  0x20, 0x96, 0x01,
                                  0x28, 0x14,
                                  0x32, 0x02, 0x47, 0x6F,
                                  0x3A, 0x01, 0x41]))
  }

  func testEncodingRespectsUTF8AndPayloadLimits() throws {
    let update = BluetoothNavigationUpdate(sequence: 0,
                                           state: .unspecified,
                                           maneuver: .unspecified,
                                           distanceMeters: 0,
                                           etaSeconds: 0,
                                           primary: "\u{00E9}\u{00E9}\u{00E9}",
                                           secondary: "")
    let payload = try XCTUnwrap(RadarNavigationPayloadEncoder.encode(update,
                                                                    maxPayloadBytes: 6,
                                                                    maxTextBytes: 5))

    XCTAssertEqual(payload, Data([0x32, 0x04, 0xC3, 0xA9, 0xC3, 0xA9]))
    XCTAssertNil(RadarNavigationPayloadEncoder.encode(update, maxPayloadBytes: 5, maxTextBytes: 5))
  }
}
