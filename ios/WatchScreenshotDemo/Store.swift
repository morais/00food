import Foundation
import Observation

// Screenshot-only substitute for WatchConnectivity, disk, haptics and widgets.
// The copied production views use the same interface, but no action can leave
// this process or modify a real account, Health store, or paired iPhone.
@MainActor @Observable final class WatchStore {
    private(set) var state = WatchScreenshotFixtures.state()
    var units: FoodUnitSystem { .metric }
    var errorMessage: String?
    var confirmation: WatchCommand?
    var pendingCount: Int { state.commands.count }
    func refresh() {}
    func log(_ food: FoodItem, quantity: Double = 1) { disabled() }
    func addWater() { disabled() }
    func estimate(_ description: String) { disabled() }
    func undo() { disabled() }
    private func disabled() { errorMessage = "Screenshot demo: saving is disabled." }
}
