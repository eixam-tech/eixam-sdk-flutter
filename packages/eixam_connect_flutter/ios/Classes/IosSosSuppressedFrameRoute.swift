/// F17c M-b: the bridge's decision for an own-TAG countdown/active frame that
/// arrives under the terminal fence (`shouldSuppressAfterTerminalSnapshot`:
/// the stale guard is armed, or the TAG just closed this SOS). The native
/// cycle always sees the frame first; this decides whether the frame also
/// follows the normal flow (snapshot, `ownDeviceSosLifecycleObserved` to Dart,
/// countdown notification) or stays hidden from Dart. Pure (Foundation only)
/// so the standalone Swift tests cover exactly what the bridge runs.
enum IosSosSuppressedFrameRoute {
  /// - cycleWasIdle / cycleIsIdle: the native cycle before / after the store
  ///   observed this frame.
  /// - staleAction: the store's `lastStaleAction` for this frame.
  /// Returns true when the frame is a new SOS that Dart must see.
  static func forwardsToDart(cycleWasIdle: Bool, cycleIsIdle: Bool, staleAction: String) -> Bool {
    // A countdown burst under the unconfirmed-stop record is a new SOS, also
    // when a countdown was kept running (portal resolve of a countdown): the
    // cycle was not idle, but Dart must still see the new SOS.
    if staleAction == "newSos" { return true }
    // Not guarded (e.g. after a TAG-confirmed close): the frame that started
    // the native cycle. Its TEL copy and later pushes land on that cycle and
    // stay hidden (Dart already has this SOS).
    return cycleWasIdle && !cycleIsIdle
  }
}
