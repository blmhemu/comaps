import Combine
import CoreBluetooth
import UIKit

@objc(BluetoothNavigationServiceBridge)
public final class BluetoothNavigationServiceBridge: NSObject {
  @objc public static func start() {
    BluetoothNavigationService.start()
  }
}

final class BluetoothNavigationService: NSObject, ObservableObject {
  @Published private(set) var devices: [BluetoothDevice] = []
  @Published private(set) var state: BluetoothScannerState = .checking

  static let shared = BluetoothNavigationService()

  private static let sequenceDefaultsKey = "BluetoothNavigationSequence"

  private let gattService = RadarNavigationGATTService()
  private var centralManager: CBCentralManager?
  private var peripherals: [UUID: CBPeripheral] = [:]
  private var navigationCharacteristics: [UUID: [CBCharacteristic]] = [:]
  private var lastNavigationUpdate: BluetoothNavigationUpdate?
  private var sequence = BluetoothNavigationService.initialSequence()
  private var deviceStorage = BluetoothDeviceStorage()
  private var isAppActive = false

  static func start() {
    guard BluetoothDeviceStorage.hasRememberedDevices else { return }
    _ = shared
  }

  private override init() {
    super.init()
    isAppActive = UIApplication.shared.applicationState == .active
    restoreKnownDevices()
    RoutingManager.routingManager.add(self)
    NotificationCenter.default.addObserver(self,
                                           selector: #selector(applicationDidBecomeActive),
                                           name: UIApplication.didBecomeActiveNotification,
                                           object: nil)
    NotificationCenter.default.addObserver(self,
                                           selector: #selector(applicationWillResignActive),
                                           name: UIApplication.willResignActiveNotification,
                                           object: nil)
    let centralManager = CBCentralManager(delegate: self, queue: .main)
    self.centralManager = centralManager
    updateScannerState(for: centralManager)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
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

  func retryScanningFromVisibleView() {
    guard state == .searching else { return }
    refresh()
  }

  func connect(_ device: BluetoothDevice) {
    deviceStorage.allow(device.id)
    guard let peripheral = peripherals[device.id] else { return }
    connectIfNeeded(peripheral, allowNewDevice: true)
  }

  func forgetDevice(_ device: BluetoothDevice) {
    deviceStorage.forget(device.id)
    navigationCharacteristics[device.id] = nil

    if let peripheral = peripherals[device.id] {
      centralManager?.cancelPeripheralConnection(peripheral)
    }

    if device.isNearby {
      mutateDevice(identifier: device.id, name: device.name) {
        $0.persistence = .discovered
        $0.connection = .disconnected
      }
    } else {
      devices.removeAll { $0.id == device.id }
    }

    if centralManager?.state == .poweredOn {
      startScanning()
    }
  }

  @objc private func applicationDidBecomeActive() {
    isAppActive = true
    refresh()
  }

  @objc private func applicationWillResignActive() {
    isAppActive = false
    centralManager?.stopScan()
  }

  private func startScanning() {
    guard isAppActive else {
      state = .searching
      return
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

  private static func initialSequence() -> UInt32 {
    let storedSequence = (UserDefaults.standard.object(forKey: sequenceDefaultsKey) as? NSNumber)?.uint32Value ?? 0
    return Swift.max(storedSequence, UInt32(Date().timeIntervalSince1970))
  }

  private func restoreKnownDevices() {
    for (identifier, name) in deviceStorage.rememberedNames {
      mutateDevice(identifier: identifier, name: name) {
        $0.persistence = .remembered
        $0.rssi = nil
        $0.connection = .disconnected
      }
    }
  }

  private func refreshKnownPeripherals() {
    guard let centralManager, centralManager.state == .poweredOn else { return }

    for peripheral in centralManager.retrievePeripherals(withIdentifiers: Array(deviceStorage.rememberedNames.keys)) {
      peripherals[peripheral.identifier] = peripheral
      peripheral.delegate = self
      mutateDevice(identifier: peripheral.identifier,
                   name: peripheral.name ?? deviceStorage.rememberedNames[peripheral.identifier]) {
        $0.persistence = .remembered
        $0.rssi = nil
        $0.connection = connectionState(for: peripheral.state)
      }
      if peripheral.state == .connected {
        peripheral.discoverServices([gattService.serviceUUID])
      } else {
        connectIfNeeded(peripheral)
      }
    }

    for peripheral in centralManager.retrieveConnectedPeripherals(withServices: [gattService.serviceUUID]) {
      guard !deviceStorage.forgottenIDs.contains(peripheral.identifier) else { continue }
      peripherals[peripheral.identifier] = peripheral
      peripheral.delegate = self
      setConnection(.connected, for: peripheral)
      peripheral.discoverServices([gattService.serviceUUID])
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
    devices.removeAll { !$0.isRemembered }
    for index in devices.indices {
      devices[index].rssi = nil
      devices[index].connection = .disconnected
    }
    peripherals.removeAll()
    navigationCharacteristics.removeAll()
  }

  private func rememberDevice(identifier: UUID, name: String?) {
    let displayName = sanitizedName(name) ?? devices.first(where: { $0.id == identifier })?.name ?? L("unknown")
    deviceStorage.remember(identifier, name: displayName)
    mutateDevice(identifier: identifier, name: displayName) {
      $0.persistence = .remembered
    }
  }

  private func isRememberedDevice(_ identifier: UUID) -> Bool {
    deviceStorage.isRemembered(identifier)
  }

  private func sanitizedName(_ name: String?) -> String? {
    guard let name, !name.isEmpty else { return nil }
    return name
  }

  private func mutateDevice(identifier: UUID,
                            name: String?,
                            mutation: (inout BluetoothDevice) -> Void) {
    if let index = devices.firstIndex(where: { $0.id == identifier }) {
      if let displayName = sanitizedName(name) {
        devices[index].name = displayName
      }
      mutation(&devices[index])
    } else {
      let displayName = sanitizedName(name) ?? deviceStorage.rememberedNames[identifier] ?? L("unknown")
      var device = BluetoothDevice(id: identifier,
                                   name: displayName,
                                   rssi: nil,
                                   persistence: isRememberedDevice(identifier) ? .remembered : .discovered,
                                   connection: .disconnected)
      mutation(&device)
      devices.append(device)
    }
    sortDevices()
  }

  private func sortDevices() {
    devices.sort { lhs, rhs in
      if lhs.connection != rhs.connection {
        return lhs.connection.rawValue > rhs.connection.rawValue
      }
      if lhs.persistence != rhs.persistence {
        return lhs.persistence == .remembered
      }
      return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  private func setConnection(_ connection: BluetoothDeviceConnectionState, for peripheral: CBPeripheral) {
    mutateDevice(identifier: peripheral.identifier, name: peripheral.name) {
      $0.connection = connection
    }
  }

  private func connectionState(for state: CBPeripheralState) -> BluetoothDeviceConnectionState {
    switch state {
    case .connected:
      return .connected
    case .connecting:
      return .connecting
    case .disconnected, .disconnecting:
      return .disconnected
    @unknown default:
      return .disconnected
    }
  }

  private func connectIfNeeded(_ peripheral: CBPeripheral, allowNewDevice: Bool = false) {
    guard centralManager?.state == .poweredOn else { return }
    guard !deviceStorage.forgottenIDs.contains(peripheral.identifier) else { return }
    guard allowNewDevice || isRememberedDevice(peripheral.identifier) else { return }
    guard peripheral.state == .disconnected else { return }
    setConnection(.connecting, for: peripheral)
    centralManager?.connect(peripheral, options: nil)
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
      sendStaticNavigationUpdate(state: .idle, maneuver: .unknown, primary: "", secondary: "")
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
    sendStaticNavigationUpdate(state: .cleared, maneuver: .unknown, primary: "", secondary: "")
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
    for (identifier, characteristics) in navigationCharacteristics {
      guard let peripheral = peripherals[identifier], peripheral.state == .connected else { continue }
      for characteristic in characteristics {
        write(update, to: characteristic, on: peripheral)
      }
    }
  }

  private func write(_ update: BluetoothNavigationUpdate,
                     to characteristic: CBCharacteristic,
                     on peripheral: CBPeripheral) {
    guard let data = gattService.encode(update) else { return }
    guard let writeType = gattService.writeType(for: characteristic) else { return }
    guard data.count <= peripheral.maximumWriteValueLength(for: writeType) else { return }
    peripheral.writeValue(data, for: characteristic, type: writeType)
  }

  private func nextSequence() -> UInt32 {
    let current = sequence
    sequence &+= 1
    UserDefaults.standard.set(Int(sequence), forKey: Self.sequenceDefaultsKey)
    return current
  }
}

extension BluetoothNavigationService: CBCentralManagerDelegate {
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
    guard gattService.matches(advertisedServices: advertisedServices, displayName: displayName) else { return }

    peripherals[peripheral.identifier] = peripheral
    peripheral.delegate = self
    let isForgotten = deviceStorage.forgottenIDs.contains(peripheral.identifier)
    mutateDevice(identifier: peripheral.identifier, name: displayName) {
      $0.rssi = RSSI.intValue
      let isRemembered = !isForgotten && deviceStorage.rememberedNames[peripheral.identifier] != nil
      $0.persistence = isRemembered ? .remembered : .discovered
      if isForgotten {
        $0.connection = .disconnected
      }
    }
    guard !isForgotten else { return }
    connectIfNeeded(peripheral)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard !deviceStorage.forgottenIDs.contains(peripheral.identifier) else {
      central.cancelPeripheralConnection(peripheral)
      setConnection(.disconnected, for: peripheral)
      return
    }
    navigationCharacteristics[peripheral.identifier] = []
    setConnection(.connected, for: peripheral)
    peripheral.discoverServices([gattService.serviceUUID])
  }

  func centralManager(_ central: CBCentralManager,
                      didDisconnectPeripheral peripheral: CBPeripheral,
                      error: Error?) {
    navigationCharacteristics[peripheral.identifier] = nil
    if deviceStorage.forgottenIDs.contains(peripheral.identifier) {
      if devices.first(where: { $0.id == peripheral.identifier })?.isNearby == true {
        mutateDevice(identifier: peripheral.identifier, name: peripheral.name) {
          $0.persistence = .discovered
          $0.connection = .disconnected
        }
      } else {
        peripherals[peripheral.identifier] = nil
        devices.removeAll { $0.id == peripheral.identifier }
      }
      return
    }
    setConnection(.disconnected, for: peripheral)
    connectIfNeeded(peripheral)
  }

  func centralManager(_ central: CBCentralManager,
                      didFailToConnect peripheral: CBPeripheral,
                      error: Error?) {
    setConnection(.disconnected, for: peripheral)
  }
}

extension BluetoothNavigationService: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard !deviceStorage.forgottenIDs.contains(peripheral.identifier) else {
      centralManager?.cancelPeripheralConnection(peripheral)
      return
    }
    guard error == nil else { return }
    for service in peripheral.services ?? [] where service.uuid == gattService.serviceUUID {
      peripheral.discoverCharacteristics(gattService.characteristicUUIDs, for: service)
    }
  }

  func peripheral(_ peripheral: CBPeripheral,
                  didDiscoverCharacteristicsFor service: CBService,
                  error: Error?) {
    guard !deviceStorage.forgottenIDs.contains(peripheral.identifier) else {
      centralManager?.cancelPeripheralConnection(peripheral)
      return
    }
    guard error == nil, service.uuid == gattService.serviceUUID else { return }
    let characteristics = service.characteristics?.filter { gattService.writeType(for: $0) != nil } ?? []
    guard !characteristics.isEmpty else {
      let hasReadyChannel = navigationCharacteristics[peripheral.identifier]?.isEmpty == false
      setConnection(hasReadyChannel ? .ready : .connected, for: peripheral)
      return
    }

    var storedCharacteristics = navigationCharacteristics[peripheral.identifier] ?? []
    for characteristic in characteristics
      where !storedCharacteristics.contains(where: { $0.uuid == characteristic.uuid }) {
      storedCharacteristics.append(characteristic)
    }
    navigationCharacteristics[peripheral.identifier] = storedCharacteristics
    rememberDevice(identifier: peripheral.identifier, name: peripheral.name)
    setConnection(.ready, for: peripheral)
    pauseScanning()

    if let lastNavigationUpdate {
      sendNavigationUpdate(lastNavigationUpdate)
    } else {
      sendCurrentNavigationUpdate()
    }
  }
}

extension BluetoothNavigationService: RoutingManagerListener {
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
