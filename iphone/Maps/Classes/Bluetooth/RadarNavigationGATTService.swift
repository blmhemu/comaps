import CoreBluetooth
import Foundation

struct RadarNavigationGATTService {
  let serviceUUID = CBUUID(string: "00000001-b691-470d-8439-e8a21d4caef5")
  let characteristicUUIDs = [CBUUID(string: "00000002-b691-470d-8439-e8a21d4caef5")]

  func matches(advertisedServices: [CBUUID], displayName: String?) -> Bool {
    advertisedServices.contains(serviceUUID) ||
      displayName?.range(of: "Radar", options: .caseInsensitive) != nil
  }

  func writeType(for characteristic: CBCharacteristic) -> CBCharacteristicWriteType? {
    guard characteristicUUIDs.contains(characteristic.uuid) else { return nil }
    if characteristic.properties.contains(.write) {
      return .withResponse
    }
    if characteristic.properties.contains(.writeWithoutResponse) {
      return .withoutResponse
    }
    return nil
  }

  func encode(_ update: BluetoothNavigationUpdate) -> Data? {
    RadarNavigationPayloadEncoder.encode(update, maxPayloadBytes: 106, maxTextBytes: 40)
  }
}
