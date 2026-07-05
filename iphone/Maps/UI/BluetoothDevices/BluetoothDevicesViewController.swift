import CoreBluetooth
import SwiftUI

private enum BluetoothNavigationSequence {
  static let defaultsKey = "BluetoothNavigationSequence"
}

private protocol BluetoothNavigationGATTService {
  var serviceUUID: CBUUID { get }
  var characteristicUUIDs: [CBUUID] { get }
  var advertisedNameFragments: [String] { get }

  func encode(_ update: BluetoothNavigationUpdate) -> Data?
}

private extension BluetoothNavigationGATTService {
  func matches(advertisedServices: [CBUUID], displayName: String?) -> Bool {
    if advertisedServices.contains(serviceUUID) {
      return true
    }
    guard let displayName else { return false }
    return advertisedNameFragments.contains {
      displayName.range(of: $0, options: .caseInsensitive) != nil
    }
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
}

private struct RadarNavigationGATTService: BluetoothNavigationGATTService {
  let serviceUUID = CBUUID(string: "00000001-b691-470d-8439-e8a21d4caef5")
  let characteristicUUIDs = [CBUUID(string: "00000002-b691-470d-8439-e8a21d4caef5")]
  let advertisedNameFragments = ["Radar"]

  private let maxPayloadBytes = 106
  private let maxTextBytes = 40

  func encode(_ update: BluetoothNavigationUpdate) -> Data? {
    RadarNavigationPayloadEncoder.encode(update,
                                         maxPayloadBytes: maxPayloadBytes,
                                         maxTextBytes: maxTextBytes)
  }
}

private enum BluetoothNavigationGATTServices {
  static let supported: [BluetoothNavigationGATTService] = [RadarNavigationGATTService()]
}

struct BluetoothDevice: Identifiable, Equatable {
  let id: UUID
  var name: String
  var rssi: NSNumber?
  var isKnown: Bool = false
  var isNearby: Bool = false
  var isConnected: Bool = false
  var isReadyForUpdates: Bool = false
}

enum BluetoothScannerState: Equatable {
  case checking
  case searching
  case idle
  case unavailable(title: String, subtitle: String?)
}

private struct BluetoothNavigationUpdate {
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

private enum RadarNavigationPayloadEncoder {
  static func encode(_ update: BluetoothNavigationUpdate,
                     maxPayloadBytes: Int,
                     maxTextBytes: Int) -> Data? {
    var data = Data()
    appendVarintField(number: 1, value: UInt64(update.sequence), to: &data)
    appendVarintField(number: 2, value: UInt64(update.state.rawValue), to: &data)
    appendVarintField(number: 3, value: UInt64(update.maneuver.rawValue), to: &data)
    appendVarintField(number: 4, value: UInt64(update.distanceMeters), to: &data)
    appendVarintField(number: 5, value: UInt64(update.etaSeconds), to: &data)
    appendStringField(number: 6, value: update.primary, maxTextBytes: maxTextBytes, to: &data)
    appendStringField(number: 7, value: update.secondary, maxTextBytes: maxTextBytes, to: &data)
    return data.count <= maxPayloadBytes ? data : nil
  }

  private static func appendVarintField(number: UInt8, value: UInt64, to data: inout Data) {
    guard value != 0 else { return }
    data.append(number << 3)
    appendVarint(value, to: &data)
  }

  private static func appendStringField(number: UInt8, value: String, maxTextBytes: Int, to data: inout Data) {
    let truncated = value.truncatedToUTF8ByteCount(maxTextBytes)
    guard !truncated.isEmpty else { return }

    let bytes = Array(truncated.utf8)
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

private extension UInt32 {
  static func clamping(_ value: Double) -> UInt32 {
    guard value.isFinite else { return 0 }
    return UInt32(Swift.min(Double(UInt32.max), Swift.max(0, value.rounded())))
  }
}

private extension RouteInfo {
  var bluetoothNavigationUpdateState: BluetoothNavigationUpdate.State {
    carDirection == .reachedYourDestination ? .arrived : .active
  }

  var bluetoothNavigationManeuver: BluetoothNavigationUpdate.Maneuver {
    switch carDirection {
    case .goStraight, .startAtEndOfStreet:
      return .straight
    case .turnRight, .exitHighwayToRight:
      return .turnRight
    case .turnSharpRight:
      return .sharpRight
    case .turnSlightRight:
      return .slightRight
    case .turnLeft, .exitHighwayToLeft:
      return .turnLeft
    case .turnSharpLeft:
      return .sharpLeft
    case .turnSlightLeft:
      return .slightLeft
    case .uTurnLeft, .uTurnRight:
      return .uTurn
    case .enterRoundAbout, .leaveRoundAbout, .stayOnRoundAbout:
      return .roundabout
    case .reachedYourDestination:
      return .destination
    case .none:
      return .unknown
    }
  }

  var bluetoothNavigationDistanceToTurnMeters: UInt32 {
    UInt32.clamping(Measurement(value: distanceToTurn, unit: turnUnits).converted(to: .meters).value)
  }

  var bluetoothNavigationEtaSeconds: UInt32 {
    UInt32.clamping(timeToTarget)
  }

  var bluetoothNavigationPrimaryText: String {
    if carDirection == .reachedYourDestination {
      return "Navigation"
    }

    let variants = NavigationInstructionFormatter.instructionVariants(roadName: roadName,
                                                                      roadRef: roadRef,
                                                                      junctionRef: junctionRef,
                                                                      destinationRef: destinationRef,
                                                                      destination: destination,
                                                                      isLink: isLink)
    return variants.first ?? carDirection.bluetoothNavigationDisplayText
  }

  var bluetoothNavigationSecondaryText: String {
    if carDirection == .reachedYourDestination {
      return "Destination"
    }
    if roundExitNumber > 0 {
      return "Exit \(roundExitNumber)"
    }
    return carDirection.bluetoothNavigationDisplayText
  }
}

private extension CarDirection {
  var bluetoothNavigationDisplayText: String {
    switch self {
    case .goStraight:
      return "Continue"
    case .turnRight:
      return "Turn right"
    case .turnSharpRight:
      return "Sharp right"
    case .turnSlightRight:
      return "Slight right"
    case .turnLeft:
      return "Turn left"
    case .turnSharpLeft:
      return "Sharp left"
    case .turnSlightLeft:
      return "Slight left"
    case .uTurnLeft, .uTurnRight:
      return "U-turn"
    case .enterRoundAbout, .stayOnRoundAbout:
      return "Roundabout"
    case .leaveRoundAbout:
      return "Exit roundabout"
    case .startAtEndOfStreet:
      return "Start route"
    case .reachedYourDestination:
      return "Arrive"
    case .exitHighwayToLeft:
      return "Exit left"
    case .exitHighwayToRight:
      return "Exit right"
    case .none:
      return "Continue"
    }
  }
}

private struct BluetoothNavigationChannel {
  let service: BluetoothNavigationGATTService
  let characteristic: CBCharacteristic
}

final class BluetoothDevicesViewModel: NSObject, ObservableObject {
  @Published private(set) var devices: [BluetoothDevice] = []
  @Published private(set) var state: BluetoothScannerState = .checking

  private static let knownDevicesDefaultsKey = "BluetoothKnownNavigationDevices"
  private static let forgottenDevicesDefaultsKey = "BluetoothForgottenNavigationDevices"
  private static var sharedInstance: BluetoothDevicesViewModel?

  private let services: [BluetoothNavigationGATTService]
  private var centralManager: CBCentralManager?
  private var peripherals: [UUID: CBPeripheral] = [:]
  private var navigationChannels: [UUID: [BluetoothNavigationChannel]] = [:]
  private var lastNavigationUpdate: BluetoothNavigationUpdate?
  private var sequence = BluetoothDevicesViewModel.initialSequence()
  private var knownDeviceNames = BluetoothDevicesViewModel.loadKnownDevices()
  private var forgottenDeviceIDs = BluetoothDevicesViewModel.loadForgottenDeviceIDs()
  private var isAppActive = false

  static func shared() -> BluetoothDevicesViewModel {
    if let sharedInstance {
      return sharedInstance
    }

    let viewModel = BluetoothDevicesViewModel(services: BluetoothNavigationGATTServices.supported)
    sharedInstance = viewModel
    return viewModel
  }

  private init(services: [BluetoothNavigationGATTService]) {
    self.services = services
    super.init()
    restoreKnownDevices()
    RoutingManager.routingManager.add(self)
    let centralManager = CBCentralManager(delegate: self, queue: .main)
    self.centralManager = centralManager
    updateScannerState(for: centralManager)
  }

  private static func initialSequence() -> UInt32 {
    let storedSequence = (UserDefaults.standard.object(forKey: BluetoothNavigationSequence.defaultsKey) as? NSNumber)?
      .uint32Value ?? 0
    let timeSequence = UInt32(Date().timeIntervalSince1970)
    return Swift.max(storedSequence, timeSequence)
  }

  deinit {
    RoutingManager.routingManager.remove(self)
    centralManager?.stopScan()
    for peripheral in peripherals.values {
      centralManager?.cancelPeripheralConnection(peripheral)
    }
  }

  func refresh() {
    guard let centralManager else {
      state = .checking
      return
    }
    updateScannerState(for: centralManager)
  }

  func appScenePhaseChanged(_ scenePhase: ScenePhase) {
    switch scenePhase {
    case .active:
      isAppActive = true
      refresh()
    case .inactive, .background:
      isAppActive = false
      centralManager?.stopScan()
    @unknown default:
      isAppActive = false
      centralManager?.stopScan()
    }
  }

  func retryScanningFromVisibleView() {
    guard state == .searching else { return }
    isAppActive = true
    refresh()
  }

  func connect(_ device: BluetoothDevice) {
    forgottenDeviceIDs.remove(device.id)
    saveForgottenDeviceIDs()
    guard let peripheral = peripherals[device.id] else { return }
    connectIfNeeded(peripheral, allowNewDevice: true)
  }

  func forgetDevice(_ device: BluetoothDevice) {
    knownDeviceNames[device.id] = nil
    saveKnownDevices()
    forgottenDeviceIDs.insert(device.id)
    saveForgottenDeviceIDs()
    navigationChannels[device.id] = nil

    if let peripheral = peripherals[device.id] {
      centralManager?.cancelPeripheralConnection(peripheral)
    }

    if device.isNearby {
      upsertDevice(identifier: device.id,
                   name: device.name,
                   rssi: device.rssi,
                   isKnown: false,
                   isNearby: true,
                   isConnected: false,
                   isReadyForUpdates: false)
    } else {
      devices.removeAll { $0.id == device.id }
    }

    if centralManager?.state == .poweredOn {
      startScanning()
    }
  }

  private func startScanning(resetDevices: Bool = false) {
    guard isAppActive else {
      state = .searching
      return
    }
    if resetDevices {
      devices.removeAll()
      peripherals.removeAll()
      navigationChannels.removeAll()
      restoreKnownDevices()
    }
    state = .searching
    refreshKnownPeripherals()
    centralManager?.stopScan()
    centralManager?.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
  }

  private func pauseScanning() {
    centralManager?.stopScan()
    state = .idle
  }

  private func stopScanning(title: String, subtitle: String?) {
    centralManager?.stopScan()
    markDevicesUnavailable()
    state = .unavailable(title: title, subtitle: subtitle)
  }

  private static func loadKnownDevices() -> [UUID: String] {
    guard let storedDevices = UserDefaults.standard.dictionary(forKey: knownDevicesDefaultsKey) as? [String: String] else {
      return [:]
    }

    return storedDevices.reduce(into: [:]) { result, device in
      guard let identifier = UUID(uuidString: device.key) else { return }
      result[identifier] = device.value
    }
  }

  private static func loadForgottenDeviceIDs() -> Set<UUID> {
    let storedIdentifiers = UserDefaults.standard.stringArray(forKey: forgottenDevicesDefaultsKey) ?? []
    return Set(storedIdentifiers.compactMap { UUID(uuidString: $0) })
  }

  private func saveKnownDevices() {
    let storedDevices = Dictionary(uniqueKeysWithValues: knownDeviceNames.map { ($0.key.uuidString, $0.value) })
    UserDefaults.standard.set(storedDevices, forKey: Self.knownDevicesDefaultsKey)
  }

  private func saveForgottenDeviceIDs() {
    let storedIdentifiers = forgottenDeviceIDs.map { $0.uuidString }
    UserDefaults.standard.set(storedIdentifiers, forKey: Self.forgottenDevicesDefaultsKey)
  }

  private func restoreKnownDevices() {
    for (identifier, name) in knownDeviceNames {
      upsertDevice(identifier: identifier,
                   name: name,
                   rssi: nil,
                   isKnown: true,
                   isNearby: false,
                   isConnected: false,
                   isReadyForUpdates: false)
    }
  }

  private func refreshKnownPeripherals() {
    guard let centralManager, centralManager.state == .poweredOn else { return }

    let knownIdentifiers = Array(knownDeviceNames.keys)
    for peripheral in centralManager.retrievePeripherals(withIdentifiers: knownIdentifiers) {
      peripherals[peripheral.identifier] = peripheral
      peripheral.delegate = self
      upsertDevice(identifier: peripheral.identifier,
                   name: peripheral.name ?? knownDeviceNames[peripheral.identifier],
                   rssi: devices.first(where: { $0.id == peripheral.identifier })?.rssi,
                   isKnown: true,
                   isNearby: false,
                   isConnected: peripheral.state == .connected,
                   isReadyForUpdates: false)
      if peripheral.state == .connected {
        peripheral.discoverServices(serviceUUIDs)
      } else {
        connectIfNeeded(peripheral)
      }
    }

    for peripheral in centralManager.retrieveConnectedPeripherals(withServices: serviceUUIDs) {
      guard !forgottenDeviceIDs.contains(peripheral.identifier) else { continue }
      peripherals[peripheral.identifier] = peripheral
      peripheral.delegate = self
      updateConnectionState(for: peripheral, isConnected: true, isReadyForUpdates: false)
      peripheral.discoverServices(serviceUUIDs)
    }
  }

  private func updateScannerState(for central: CBCentralManager) {
    switch central.state {
    case .poweredOn:
      startScanning()
    case .poweredOff:
      stopScanning(title: L("bluetooth_devices_powered_off_title"), subtitle: L("bluetooth_devices_powered_off"))
    case .unauthorized:
      stopScanning(title: L("bluetooth_devices_permission_needed"), subtitle: L("bluetooth_devices_unauthorized"))
    case .unsupported:
      stopScanning(title: L("bluetooth_devices_unavailable"), subtitle: L("bluetooth_devices_unsupported"))
    case .resetting, .unknown:
      central.stopScan()
      markDevicesUnavailable()
      state = .checking
    @unknown default:
      stopScanning(title: L("bluetooth_devices_unavailable"), subtitle: nil)
    }
  }

  private func markDevicesUnavailable() {
    devices.removeAll { !$0.isKnown }
    for index in devices.indices {
      devices[index].rssi = nil
      devices[index].isNearby = false
      devices[index].isConnected = false
      devices[index].isReadyForUpdates = false
    }
    peripherals.removeAll()
    navigationChannels.removeAll()
  }

  private func rememberDevice(identifier: UUID, name: String?) {
    forgottenDeviceIDs.remove(identifier)
    saveForgottenDeviceIDs()
    let displayName = sanitizedName(name) ?? devices.first(where: { $0.id == identifier })?.name ?? L("unknown")
    knownDeviceNames[identifier] = displayName
    saveKnownDevices()
    upsertDevice(identifier: identifier,
                 name: displayName,
                 rssi: devices.first(where: { $0.id == identifier })?.rssi,
                 isKnown: true)
  }

  private func isRememberedDevice(_ identifier: UUID) -> Bool {
    knownDeviceNames[identifier] != nil && !forgottenDeviceIDs.contains(identifier)
  }

  private func sanitizedName(_ name: String?) -> String? {
    guard let name = name, !name.isEmpty else { return nil }
    return name
  }

  private func sortDevices() {
    devices.sort { lhs, rhs in
      if lhs.isReadyForUpdates != rhs.isReadyForUpdates {
        return lhs.isReadyForUpdates
      }
      if lhs.isConnected != rhs.isConnected {
        return lhs.isConnected
      }
      if lhs.isKnown != rhs.isKnown {
        return lhs.isKnown
      }
      return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  private func upsertDevice(identifier: UUID,
                            name: String?,
                            rssi: NSNumber?,
                            isKnown: Bool? = nil,
                            isNearby: Bool? = nil,
                            isConnected: Bool? = nil,
                            isReadyForUpdates: Bool? = nil) {
    if let index = devices.firstIndex(where: { $0.id == identifier }) {
      if let displayName = sanitizedName(name) {
        devices[index].name = displayName
      }
      if let rssi {
        devices[index].rssi = rssi
      }
      if let isKnown {
        devices[index].isKnown = isKnown
      }
      if let isNearby {
        devices[index].isNearby = isNearby
      }
      if let isConnected {
        devices[index].isConnected = isConnected
      }
      if let isReadyForUpdates {
        devices[index].isReadyForUpdates = isReadyForUpdates
      }
    } else {
      let displayName = sanitizedName(name) ?? knownDeviceNames[identifier] ?? L("unknown")
      devices.append(BluetoothDevice(id: identifier,
                                     name: displayName,
                                     rssi: rssi,
                                     isKnown: isKnown ?? (knownDeviceNames[identifier] != nil),
                                     isNearby: isNearby ?? (rssi != nil),
                                     isConnected: isConnected ?? false,
                                     isReadyForUpdates: isReadyForUpdates ?? false))
    }
    sortDevices()
  }

  private func updateConnectionState(for peripheral: CBPeripheral,
                                     isConnected: Bool,
                                     isReadyForUpdates: Bool? = nil) {
    let existingDevice = devices.first { $0.id == peripheral.identifier }
    upsertDevice(identifier: peripheral.identifier,
                 name: peripheral.name,
                 rssi: existingDevice?.rssi,
                 isKnown: existingDevice?.isKnown ?? (knownDeviceNames[peripheral.identifier] != nil),
                 isNearby: existingDevice?.isNearby,
                 isConnected: isConnected,
                 isReadyForUpdates: isReadyForUpdates)
  }

  private func connectIfNeeded(_ peripheral: CBPeripheral, allowNewDevice: Bool = false) {
    guard centralManager?.state == .poweredOn else { return }
    guard !forgottenDeviceIDs.contains(peripheral.identifier) else { return }
    guard allowNewDevice || isRememberedDevice(peripheral.identifier) else { return }
    guard peripheral.state == .disconnected else { return }
    centralManager?.connect(peripheral, options: nil)
  }

  private var serviceUUIDs: [CBUUID] {
    services.map { $0.serviceUUID }
  }

  private func service(for uuid: CBUUID) -> BluetoothNavigationGATTService? {
    services.first { $0.serviceUUID == uuid }
  }

  private func matchesSupportedService(advertisedServices: [CBUUID], displayName: String?) -> Bool {
    services.contains { $0.matches(advertisedServices: advertisedServices, displayName: displayName) }
  }

  private func sendCurrentNavigationUpdate() {
    let manager = RoutingManager.routingManager
    if manager.isRouteFinished {
      sendStaticNavigationUpdate(state: .arrived,
                                 maneuver: .destination,
                                 primary: "Navigation",
                                 secondary: "Destination")
      return
    }

    guard manager.isOnRoute else {
      sendStaticNavigationUpdate(state: .idle,
                                 maneuver: .unknown,
                                 primary: "",
                                 secondary: "")
      return
    }

    guard let routeInfo = manager.routeInfo else {
      sendStaticNavigationUpdate(state: .rerouting,
                                 maneuver: .unknown,
                                 primary: "Navigation",
                                 secondary: "Please wait")
      return
    }

    sendNavigationUpdate(BluetoothNavigationUpdate(sequence: nextSequence(),
                                                   state: routeInfo.bluetoothNavigationUpdateState,
                                                   maneuver: routeInfo.bluetoothNavigationManeuver,
                                                   distanceMeters: routeInfo.bluetoothNavigationDistanceToTurnMeters,
                                                   etaSeconds: routeInfo.bluetoothNavigationEtaSeconds,
                                                   primary: routeInfo.bluetoothNavigationPrimaryText,
                                                   secondary: routeInfo.bluetoothNavigationSecondaryText))
  }

  private func sendClearedNavigationUpdate() {
    sendStaticNavigationUpdate(state: .cleared,
                               maneuver: .unknown,
                               primary: "",
                               secondary: "")
  }

  private func sendStaticNavigationUpdate(state: BluetoothNavigationUpdate.State,
                                          maneuver: BluetoothNavigationUpdate.Maneuver,
                                          primary: String,
                                          secondary: String) {
    sendNavigationUpdate(BluetoothNavigationUpdate(sequence: nextSequence(),
                                                   state: state,
                                                   maneuver: maneuver,
                                                   distanceMeters: 0,
                                                   etaSeconds: 0,
                                                   primary: primary,
                                                   secondary: secondary))
  }

  private func sendNavigationUpdate(_ update: BluetoothNavigationUpdate) {
    lastNavigationUpdate = update
    for (identifier, channels) in navigationChannels {
      guard let peripheral = peripherals[identifier], peripheral.state == .connected else { continue }
      for channel in channels {
        write(update, to: channel.characteristic, using: channel.service, on: peripheral)
      }
    }
  }

  private func write(_ update: BluetoothNavigationUpdate,
                     to characteristic: CBCharacteristic,
                     using service: BluetoothNavigationGATTService,
                     on peripheral: CBPeripheral) {
    guard let data = service.encode(update) else { return }
    guard let writeType = service.writeType(for: characteristic) else { return }
    guard data.count <= peripheral.maximumWriteValueLength(for: writeType) else { return }
    peripheral.writeValue(data, for: characteristic, type: writeType)
  }

  private func nextSequence() -> UInt32 {
    let current = sequence
    sequence &+= 1
    UserDefaults.standard.set(Int(sequence), forKey: BluetoothNavigationSequence.defaultsKey)
    return current
  }
}

extension BluetoothDevicesViewModel: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    updateScannerState(for: central)
  }

  func centralManager(_ central: CBCentralManager,
                      didDiscover peripheral: CBPeripheral,
                      advertisementData: [String: Any],
                      rssi RSSI: NSNumber) {
    let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
    let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
    let displayName = peripheral.name ?? localName
    guard matchesSupportedService(advertisedServices: advertisedServices, displayName: displayName) else { return }

    peripherals[peripheral.identifier] = peripheral
    peripheral.delegate = self
    let isForgotten = forgottenDeviceIDs.contains(peripheral.identifier)
    upsertDevice(identifier: peripheral.identifier,
                 name: displayName,
                 rssi: RSSI,
                 isKnown: !isForgotten && knownDeviceNames[peripheral.identifier] != nil,
                 isNearby: true,
                 isConnected: isForgotten ? false : nil,
                 isReadyForUpdates: isForgotten ? false : nil)
    guard !isForgotten else { return }
    connectIfNeeded(peripheral)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard !forgottenDeviceIDs.contains(peripheral.identifier) else {
      central.cancelPeripheralConnection(peripheral)
      updateConnectionState(for: peripheral, isConnected: false, isReadyForUpdates: false)
      return
    }
    navigationChannels[peripheral.identifier] = []
    updateConnectionState(for: peripheral, isConnected: true, isReadyForUpdates: false)
    peripheral.discoverServices(serviceUUIDs)
  }

  func centralManager(_ central: CBCentralManager,
                      didDisconnectPeripheral peripheral: CBPeripheral,
                      error: Error?) {
    navigationChannels[peripheral.identifier] = nil
    if forgottenDeviceIDs.contains(peripheral.identifier) {
      let existingDevice = devices.first { $0.id == peripheral.identifier }
      if existingDevice?.isNearby == true {
        upsertDevice(identifier: peripheral.identifier,
                     name: peripheral.name,
                     rssi: existingDevice?.rssi,
                     isKnown: false,
                     isNearby: true,
                     isConnected: false,
                     isReadyForUpdates: false)
      } else {
        peripherals[peripheral.identifier] = nil
        devices.removeAll { $0.id == peripheral.identifier }
      }
      return
    }
    updateConnectionState(for: peripheral, isConnected: false, isReadyForUpdates: false)
    connectIfNeeded(peripheral)
  }

  func centralManager(_ central: CBCentralManager,
                      didFailToConnect peripheral: CBPeripheral,
                      error: Error?) {
    if forgottenDeviceIDs.contains(peripheral.identifier) {
      updateConnectionState(for: peripheral, isConnected: false, isReadyForUpdates: false)
      return
    }
    updateConnectionState(for: peripheral, isConnected: false, isReadyForUpdates: false)
  }
}

extension BluetoothDevicesViewModel: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard !forgottenDeviceIDs.contains(peripheral.identifier) else {
      centralManager?.cancelPeripheralConnection(peripheral)
      return
    }
    guard error == nil else { return }
    peripheral.services?
      .forEach { service in
        guard let navigationService = self.service(for: service.uuid) else { return }
        peripheral.discoverCharacteristics(navigationService.characteristicUUIDs, for: service)
      }
  }

  func peripheral(_ peripheral: CBPeripheral,
                  didDiscoverCharacteristicsFor service: CBService,
                  error: Error?) {
    guard !forgottenDeviceIDs.contains(peripheral.identifier) else {
      centralManager?.cancelPeripheralConnection(peripheral)
      return
    }
    guard error == nil, let navigationService = self.service(for: service.uuid) else { return }
    let characteristics = service.characteristics?.filter {
      navigationService.writeType(for: $0) != nil
    } ?? []
    guard !characteristics.isEmpty else {
      let hasReadyChannel = navigationChannels[peripheral.identifier]?.isEmpty == false
      updateConnectionState(for: peripheral, isConnected: true, isReadyForUpdates: hasReadyChannel)
      return
    }

    var channels = navigationChannels[peripheral.identifier] ?? []
    for characteristic in characteristics {
      guard !channels.contains(where: {
        $0.service.serviceUUID == navigationService.serviceUUID &&
          $0.characteristic.uuid == characteristic.uuid
      }) else { continue }
      channels.append(BluetoothNavigationChannel(service: navigationService, characteristic: characteristic))
    }
    navigationChannels[peripheral.identifier] = channels
    rememberDevice(identifier: peripheral.identifier, name: peripheral.name)
    updateConnectionState(for: peripheral, isConnected: true, isReadyForUpdates: true)
    pauseScanning()

    if let lastNavigationUpdate {
      sendNavigationUpdate(lastNavigationUpdate)
    } else {
      sendCurrentNavigationUpdate()
    }
  }
}

extension BluetoothDevicesViewModel: RoutingManagerListener {
  func updateCameraInfo(isCameraOnRoute: Bool, speedLimitMps limit: Double) {}

  func processRouteBuilderEvent(with code: RouterResultCode, countries: [String]) {
    DispatchQueue.main.async { [weak self] in
      switch code {
      case .noError, .hasWarnings:
        self?.sendCurrentNavigationUpdate()
      case .cancelled:
        self?.sendClearedNavigationUpdate()
      default:
        self?.sendClearedNavigationUpdate()
      }
    }
  }

  func didLocationUpdate(_ notifications: [String]) {
    DispatchQueue.main.async { [weak self] in
      self?.sendCurrentNavigationUpdate()
    }
  }
}

struct BluetoothDevicesView: View {
  @ObservedObject var viewModel: BluetoothDevicesViewModel
  @Environment(\.scenePhase) private var scenePhase
  let onClose: () -> Void
  @State private var deviceToForget: BluetoothDevice?

  var body: some View {
    deviceList
    .navigationTitle(L("bluetooth_devices"))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .navigationBarTrailing) {
        Button(action: onClose) {
          Image(systemName: "xmark")
        }
        .accessibilityLabel(Text(L("close")))
      }
    }
    .onAppear {
      viewModel.appScenePhaseChanged(scenePhase)
    }
    .onChange(of: scenePhase) { phase in
      viewModel.appScenePhaseChanged(phase)
    }
    .task(id: viewModel.state) {
      guard viewModel.state == .searching else { return }
      while !Task.isCancelled && viewModel.state == .searching {
        viewModel.retryScanningFromVisibleView()
        do {
          try await Task.sleep(nanoseconds: 3_000_000_000)
        } catch {
          return
        }
      }
    }
    .confirmationDialog(L("bluetooth_devices_forget_title"),
                        isPresented: isForgetConfirmationPresented,
                        titleVisibility: .visible) {
      Button(L("bluetooth_devices_forget_device"), role: .destructive) {
        if let deviceToForget {
          viewModel.forgetDevice(deviceToForget)
        }
        deviceToForget = nil
      }
      Button(L("cancel"), role: .cancel) {
        deviceToForget = nil
      }
    } message: {
      Text(L("bluetooth_devices_forget_message"))
    }
  }

  private var isForgetConfirmationPresented: Binding<Bool> {
    Binding(get: {
      deviceToForget != nil
    }, set: { isPresented in
      if !isPresented {
        deviceToForget = nil
      }
    })
  }

  private var deviceList: some View {
    List {
      scannerStatusSection

      if !myDevices.isEmpty {
        Section(header: Text(L("bluetooth_devices_my_devices"))) {
          ForEach(myDevices) { device in
            deviceRow(device)
          }
        }
      }

      if !nearbyDevices.isEmpty || viewModel.state == .searching {
        Section(header: Text(L("bluetooth_devices_nearby_devices"))) {
          ForEach(nearbyDevices) { device in
            deviceRow(device)
          }
          if viewModel.state == .searching {
            searchingRow
          }
        }
      }
    }
    .listStyle(.insetGrouped)
  }

  private var myDevices: [BluetoothDevice] {
    viewModel.devices.filter { $0.isKnown || $0.isConnected || $0.isReadyForUpdates }
  }

  private var nearbyDevices: [BluetoothDevice] {
    viewModel.devices.filter { !$0.isKnown && !$0.isConnected && !$0.isReadyForUpdates && $0.isNearby }
  }

  @ViewBuilder
  private var scannerStatusSection: some View {
    switch viewModel.state {
    case .checking:
      Section {
        statusRow(title: L("bluetooth_devices_checking"), subtitle: nil, showsProgress: true)
      }
    case let .unavailable(title, subtitle):
      Section {
        statusRow(title: title, subtitle: subtitle, showsProgress: false)
      }
    case .searching, .idle:
      EmptyView()
    }
  }

  private var searchingRow: some View {
    HStack(spacing: 12) {
      ProgressView()
      Text(L("bluetooth_devices_searching"))
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }

  private func statusRow(title: String, subtitle: String?, showsProgress: Bool) -> some View {
    HStack(alignment: .top, spacing: 12) {
      if showsProgress {
        ProgressView()
      } else {
        Image(systemName: "bluetooth.slash")
          .font(.title3)
          .foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.body.weight(.medium))
        if let subtitle {
          Text(subtitle)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 4)
  }

  private func deviceRow(_ device: BluetoothDevice) -> some View {
    HStack(spacing: 12) {
      Image(systemName: deviceIconName(for: device))
        .font(.title3)
        .foregroundColor(device.isReadyForUpdates ? .green : .secondary)
      VStack(alignment: .leading, spacing: 3) {
        Text(device.name)
          .font(.body)
        Text(deviceStatusText(for: device))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if device.isReadyForUpdates {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
      } else if device.isConnected {
        Image(systemName: "checkmark.circle")
          .foregroundStyle(.secondary)
      }
      if device.isKnown {
        Button {
          deviceToForget = device
        } label: {
          Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(L("bluetooth_devices_device_info")))
      }
    }
    .contentShape(Rectangle())
    .onTapGesture {
      if canConnect(device) {
        viewModel.connect(device)
      }
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      if device.isKnown {
        Button(role: .destructive) {
          deviceToForget = device
        } label: {
          Label(L("bluetooth_devices_forget_device"), systemImage: "trash")
        }
      }
    }
    .padding(.vertical, 4)
  }

  private func canConnect(_ device: BluetoothDevice) -> Bool {
    device.isNearby && !device.isConnected && !device.isReadyForUpdates
  }

  private func deviceIconName(for device: BluetoothDevice) -> String {
    device.isConnected || device.isReadyForUpdates ? "bluetooth" : "antenna.radiowaves.left.and.right"
  }

  private func deviceStatusText(for device: BluetoothDevice) -> String {
    if device.isReadyForUpdates {
      return L("bluetooth_devices_status_ready")
    }
    if device.isConnected {
      return L("bluetooth_devices_status_connected")
    }
    if !device.isNearby {
      return L("bluetooth_devices_status_not_connected")
    }
    if canConnect(device) {
      return String(format: L("bluetooth_devices_status_tap_to_connect"), signalDescription(for: device.rssi))
    }
    return signalDescription(for: device.rssi)
  }

  private func signalDescription(for rssi: NSNumber?) -> String {
    guard let value = rssi?.intValue else { return L("bluetooth_devices_signal_nearby") }
    if value >= -55 {
      return L("bluetooth_devices_signal_very_close")
    }
    if value >= -70 {
      return L("bluetooth_devices_signal_nearby")
    }
    if value >= -85 {
      return L("bluetooth_devices_signal_far")
    }
    return L("bluetooth_devices_signal_weak")
  }
}

final class BluetoothDevicesViewController: UIHostingController<BluetoothDevicesView> {
  private let viewModel: BluetoothDevicesViewModel

  init() {
    let viewModel = BluetoothDevicesViewModel.shared()
    self.viewModel = viewModel
    super.init(rootView: BluetoothDevicesView(viewModel: viewModel, onClose: {}))
    rootView = BluetoothDevicesView(viewModel: viewModel) { [weak self] in
      self?.close()
    }
  }

  @available(*, unavailable)
  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func close() {
    dismiss(animated: true)
  }
}
