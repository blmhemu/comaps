import Foundation

enum RadarNavigationPayloadEncoder {
  static func encode(_ update: BluetoothNavigationUpdate,
                     maxPayloadBytes: Int,
                     maxTextBytes: Int) -> Data? {
    var data = Data()
    appendVarintField(number: 1, value: UInt64(update.sequence), to: &data)
    appendVarintField(number: 2, value: UInt64(update.state.rawValue), to: &data)
    appendVarintField(number: 3, value: UInt64(update.maneuver.rawValue), to: &data)
    appendVarintField(number: 4, value: UInt64(update.distanceMeters), to: &data)
    appendVarintField(number: 5, value: UInt64(update.etaSeconds), to: &data)
    appendStringField(number: 6, value: update.primary, maxBytes: maxTextBytes, to: &data)
    appendStringField(number: 7, value: update.secondary, maxBytes: maxTextBytes, to: &data)
    return data.count <= maxPayloadBytes ? data : nil
  }

  private static func appendVarintField(number: UInt8, value: UInt64, to data: inout Data) {
    guard value != 0 else { return }
    data.append(number << 3)
    appendVarint(value, to: &data)
  }

  private static func appendStringField(number: UInt8,
                                        value: String,
                                        maxBytes: Int,
                                        to data: inout Data) {
    let value = value.truncatedToUTF8ByteCount(maxBytes)
    guard !value.isEmpty else { return }

    let bytes = Array(value.utf8)
    data.append((number << 3) | 2)
    appendVarint(UInt64(bytes.count), to: &data)
    data.append(contentsOf: bytes)
  }

  private static func appendVarint(_ value: UInt64, to data: inout Data) {
    var value = value
    while value >= 0x80 {
      data.append(UInt8(value & 0x7F) | 0x80)
      value >>= 7
    }
    data.append(UInt8(value))
  }
}

private extension String {
  func truncatedToUTF8ByteCount(_ maxBytes: Int) -> String {
    var result = ""
    var byteCount = 0
    for character in self {
      let characterByteCount = String(character).utf8.count
      guard byteCount + characterByteCount <= maxBytes else { break }
      result.append(character)
      byteCount += characterByteCount
    }
    return result
  }
}
