import Foundation

enum BluetoothDevicePersistenceState: Equatable {
  case discovered
  case remembered
}

enum BluetoothDeviceConnectionState: Int, Equatable {
  case disconnected
  case connecting
  case connected
  case ready
}

struct BluetoothDevice: Identifiable, Equatable {
  let id: UUID
  var name: String
  var rssi: Int?
  var persistence: BluetoothDevicePersistenceState
  var connection: BluetoothDeviceConnectionState

  var isRemembered: Bool { persistence == .remembered }
  var isNearby: Bool { rssi != nil }
  var isConnected: Bool { connection == .connected || connection == .ready }
  var isReadyForUpdates: Bool { connection == .ready }
}

enum BluetoothScannerState: Equatable {
  case checking
  case searching
  case idle
  case unavailable(title: String, subtitle: String?)
}

struct BluetoothNavigationUpdate {
  enum State: UInt32 {
    case unspecified = 0
    case idle = 1
    case active = 2
    case rerouting = 3
    case arrived = 4
    case cleared = 5
  }

  enum Maneuver: UInt32 {
    case unspecified = 0
    case unknown = 1
    case straight = 2
    case turnLeft = 3
    case turnRight = 4
    case slightLeft = 5
    case slightRight = 6
    case sharpLeft = 7
    case sharpRight = 8
    case uTurn = 9
    case roundabout = 10
    case destination = 11
  }

  let sequence: UInt32
  let state: State
  let maneuver: Maneuver
  let distanceMeters: UInt32
  let etaSeconds: UInt32
  let primary: String
  let secondary: String
}
