import Foundation

#if os(iOS)
import UIKit

/// Reference-counted screen-awake claims. Resolver evaluation and a running
/// tunnel can overlap, so a simple boolean would let one view accidentally
/// re-enable the idle timer while the other is still active.
@MainActor
public final class IdleTimerController {
    public static let shared = IdleTimerController()

    private var claims = 0

    private init() {}

    public func acquire() {
        claims += 1
        UIApplication.shared.isIdleTimerDisabled = claims > 0
    }

    public func release() {
        claims = max(0, claims - 1)
        UIApplication.shared.isIdleTimerDisabled = claims > 0
    }

    public func reset() {
        claims = 0
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
#endif
