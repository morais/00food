import Foundation

enum OnboardingReplay {
    static let requestKey = "onboarding.replayOnNextLaunch"

    // Called once when the App is created, so enabling the switch during this
    // run cannot replace the current screen or replay on a foreground refresh.
    static func consumeRequest(defaults: UserDefaults = .standard) -> Bool {
        let requested = defaults.bool(forKey: requestKey)
        if requested { defaults.set(false, forKey: requestKey) }
        return requested
    }
}

enum OnboardingStep: Equatable {
    case welcome, essentials, pace

    static func afterHealth(heightCm: Double?, weightKg: Double?) -> OnboardingStep {
        // Biological sex and body fat are optional. Saved/manual details cannot
        // stand in for missing Health readings when deciding to skip this form.
        guard let heightCm, let weightKg, heightCm.isFinite, weightKg.isFinite,
              (100...250).contains(heightCm), (25...400).contains(weightKg) else { return .essentials }
        return .pace
    }
}

struct OnboardingDraft {
    var height: String
    var weight: String
    var estimateProfile: String
    var deficitPercent: Int

    init(saved: FoodProfile?, healthHeightCm: Double?, healthWeightKg: Double?, healthEstimateProfile: String?) {
        height = (healthHeightCm ?? saved?.heightCm).map { String($0) } ?? ""
        weight = (healthWeightKg ?? saved?.weightKg).map { String($0) } ?? ""
        estimateProfile = healthEstimateProfile ?? saved?.estimateProfile ?? "neutral"
        deficitPercent = saved?.deficitPercent ?? DeficitLevel.gentle.rawValue
    }

    var profile: FoodProfile? {
        func number(_ text: String) -> Double? {
            Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
        }
        guard let heightCm = number(height), let weightKg = number(weight),
              heightCm.isFinite, weightKg.isFinite,
              (100...250).contains(heightCm), (25...400).contains(weightKg) else { return nil }
        return FoodProfile(heightCm: heightCm, weightKg: weightKg,
                           estimateProfile: estimateProfile, deficitPercent: deficitPercent)
    }
}
