import Foundation

struct BluetoothDeviceStorage {
  private enum Key {
    static let remembered = "BluetoothKnownNavigationDevices"
    static let forgotten = "BluetoothForgottenNavigationDevices"
  }

  private let defaults: UserDefaults
  private(set) var rememberedNames: [UUID: String]
  private(set) var forgottenIDs: Set<UUID>

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let storedNames = defaults.dictionary(forKey: Key.remembered) as? [String: String] ?? [:]
    rememberedNames = storedNames.reduce(into: [:]) { result, device in
      guard let identifier = UUID(uuidString: device.key) else { return }
      result[identifier] = device.value
    }
    forgottenIDs = Set((defaults.stringArray(forKey: Key.forgotten) ?? []).compactMap(UUID.init(uuidString:)))
  }

  static var hasRememberedDevices: Bool {
    !BluetoothDeviceStorage().rememberedNames.isEmpty
  }

  func isRemembered(_ identifier: UUID) -> Bool {
    rememberedNames[identifier] != nil && !forgottenIDs.contains(identifier)
  }

  mutating func allow(_ identifier: UUID) {
    guard forgottenIDs.remove(identifier) != nil else { return }
    saveForgottenIDs()
  }

  mutating func remember(_ identifier: UUID, name: String) {
    forgottenIDs.remove(identifier)
    rememberedNames[identifier] = name
    saveForgottenIDs()
    saveRememberedNames()
  }

  mutating func forget(_ identifier: UUID) {
    rememberedNames[identifier] = nil
    forgottenIDs.insert(identifier)
    saveRememberedNames()
    saveForgottenIDs()
  }

  private func saveRememberedNames() {
    let storedNames = Dictionary(uniqueKeysWithValues: rememberedNames.map { ($0.key.uuidString, $0.value) })
    defaults.set(storedNames, forKey: Key.remembered)
  }

  private func saveForgottenIDs() {
    defaults.set(forgottenIDs.map(\.uuidString), forKey: Key.forgotten)
  }
}
