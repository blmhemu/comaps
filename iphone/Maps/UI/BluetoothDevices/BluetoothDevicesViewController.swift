import SwiftUI

final class BluetoothDevicesViewController: UIHostingController<BluetoothDevicesView> {
  init(service: BluetoothNavigationService = .shared) {
    super.init(rootView: BluetoothDevicesView(service: service, onClose: {}))
    rootView = BluetoothDevicesView(service: service) { [weak self] in
      self?.dismiss(animated: true)
    }
  }

  @available(*, unavailable)
  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
