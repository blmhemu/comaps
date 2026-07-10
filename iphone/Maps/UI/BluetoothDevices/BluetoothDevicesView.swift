import SwiftUI

struct BluetoothDevicesView: View {
  @ObservedObject var service: BluetoothNavigationService
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
        service.refresh()
      }
      .task(id: service.state) {
        guard service.state == .searching else { return }
        while !Task.isCancelled && service.state == .searching {
          service.retryScanningFromVisibleView()
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
            service.forgetDevice(deviceToForget)
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

      if !nearbyDevices.isEmpty || service.state == .searching {
        Section(header: Text(L("bluetooth_devices_nearby_devices"))) {
          ForEach(nearbyDevices) { device in
            deviceRow(device)
          }
          if service.state == .searching {
            searchingRow
          }
        }
      }
    }
    .listStyle(.insetGrouped)
  }

  private var myDevices: [BluetoothDevice] {
    service.devices.filter { $0.isRemembered || $0.connection != .disconnected }
  }

  private var nearbyDevices: [BluetoothDevice] {
    service.devices.filter { !$0.isRemembered && $0.connection == .disconnected && $0.isNearby }
  }

  @ViewBuilder
  private var scannerStatusSection: some View {
    switch service.state {
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
      Image(systemName: device.isConnected ? "bluetooth" : "antenna.radiowaves.left.and.right")
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
      if device.isRemembered {
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
        service.connect(device)
      }
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      if device.isRemembered {
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
    device.isNearby && device.connection == .disconnected
  }

  private func deviceStatusText(for device: BluetoothDevice) -> String {
    switch device.connection {
    case .ready:
      return L("bluetooth_devices_status_ready")
    case .connected:
      return L("bluetooth_devices_status_connected")
    case .connecting:
      return L("bluetooth_devices_status_connecting")
    case .disconnected:
      guard device.isNearby else { return L("bluetooth_devices_status_not_connected") }
      return String(format: L("bluetooth_devices_status_tap_to_connect"), signalDescription(for: device.rssi))
    }
  }

  private func signalDescription(for rssi: Int?) -> String {
    guard let rssi else { return L("bluetooth_devices_signal_nearby") }
    if rssi >= -55 {
      return L("bluetooth_devices_signal_very_close")
    }
    if rssi >= -70 {
      return L("bluetooth_devices_signal_nearby")
    }
    if rssi >= -85 {
      return L("bluetooth_devices_signal_far")
    }
    return L("bluetooth_devices_signal_weak")
  }
}
