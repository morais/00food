import AppIntents
import Foundation

enum FoodLogDestination: String, AppEnum {
    case log
    case camera

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Food log screen")
    static var caseDisplayRepresentations: [FoodLogDestination: DisplayRepresentation] = [
        .log: "Log food",
        .camera: "Photograph food",
    ]
}

struct OpenFoodLogIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open food log"
    static var description = IntentDescription("Open 00Food to log a meal.")

    @Parameter(title: "Screen") var target: FoodLogDestination

    init() { target = .log }
    init(target: FoodLogDestination) { self.target = target }

    func perform() async throws -> some IntentResult {
        FoodWidgetSnapshotStore.sharedDefaults?.set(target.rawValue, forKey: FoodWidgetSnapshotStore.pendingLaunchKey)
        return .result()
    }
}
