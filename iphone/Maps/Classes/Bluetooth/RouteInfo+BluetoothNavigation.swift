import Foundation

extension RouteInfo {
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
    UInt32(clamping: Measurement(value: distanceToTurn, unit: turnUnits).converted(to: .meters).value)
  }

  var bluetoothNavigationEtaSeconds: UInt32 {
    UInt32(clamping: timeToTarget)
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

private extension UInt32 {
  init(clamping value: Double) {
    guard value.isFinite else {
      self = 0
      return
    }
    self = UInt32(Swift.min(Double(UInt32.max), Swift.max(0, value.rounded())))
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
