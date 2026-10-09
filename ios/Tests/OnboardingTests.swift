import XCTest
@testable import ZeroZeroFood

final class OnboardingTests: XCTestCase {
    func testReplayIsConsumedOnlyOnceAtLaunch() {
        let suite = "OnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(OnboardingReplay.consumeRequest(defaults: defaults))
        defaults.set(true, forKey: OnboardingReplay.requestKey)
        XCTAssertTrue(defaults.bool(forKey: OnboardingReplay.requestKey))
        XCTAssertTrue(OnboardingReplay.consumeRequest(defaults: defaults))
        XCTAssertFalse(defaults.bool(forKey: OnboardingReplay.requestKey))
        XCTAssertFalse(OnboardingReplay.consumeRequest(defaults: defaults))
    }

    func testHealthPrefillsDetailsAndReplayPreservesCurrentPlan() throws {
        let saved = FoodProfile(heightCm: 160, weightKg: 70, estimateProfile: "neutral", deficitPercent: 0)
        let draft = OnboardingDraft(saved: saved, healthHeightCm: 175, healthWeightKg: 80,
                                    healthEstimateProfile: "female")
        let profile = try XCTUnwrap(draft.profile)
        XCTAssertEqual(profile.heightCm, 175)
        XCTAssertEqual(profile.weightKg, 80)
        XCTAssertEqual(profile.estimateProfile, "female")
        XCTAssertEqual(profile.deficitPercent, 0)
        XCTAssertEqual(saved.heightCm, 160)
    }

    func testMissingHealthDetailsUseSavedValuesWithoutChangingThePlan() throws {
        let saved = FoodProfile(heightCm: 175, weightKg: 80, estimateProfile: "male", deficitPercent: 20)
        let draft = OnboardingDraft(saved: saved, healthHeightCm: nil, healthWeightKg: nil,
                                    healthEstimateProfile: nil)
        XCTAssertEqual(try XCTUnwrap(draft.profile), saved)
    }

    func testCompleteHealthDetailsSkipEssentialsEvenWithoutBiologicalSex() throws {
        XCTAssertEqual(OnboardingStep.afterHealth(heightCm: 175, weightKg: 80), .pace)
        let draft = OnboardingDraft(saved: nil, healthHeightCm: 175, healthWeightKg: 80,
                                    healthEstimateProfile: nil)
        XCTAssertEqual(try XCTUnwrap(draft.profile).estimateProfile, "neutral")
    }

    func testMissingOrInvalidHealthDetailsRequireEssentials() {
        XCTAssertEqual(OnboardingStep.afterHealth(heightCm: nil, weightKg: 80), .essentials)
        XCTAssertEqual(OnboardingStep.afterHealth(heightCm: 175, weightKg: nil), .essentials)
        XCTAssertEqual(OnboardingStep.afterHealth(heightCm: .nan, weightKg: 80), .essentials)
        XCTAssertEqual(OnboardingStep.afterHealth(heightCm: 175, weightKg: .infinity), .essentials)
        XCTAssertEqual(OnboardingStep.afterHealth(heightCm: 99, weightKg: 80), .essentials)
        XCTAssertEqual(OnboardingStep.afterHealth(heightCm: 175, weightKg: 401), .essentials)
    }

    func testPaceChoiceIsSavedWithTheDetailsAndSurvivesEditing() throws {
        var draft = OnboardingDraft(saved: nil, healthHeightCm: 175, healthWeightKg: 80,
                                    healthEstimateProfile: "female")
        for level in DeficitLevel.allCases {
            draft.deficitPercent = level.rawValue
            XCTAssertEqual(try XCTUnwrap(draft.profile).deficitPercent, level.rawValue)
        }
        draft.height = "176"
        XCTAssertEqual(try XCTUnwrap(draft.profile).deficitPercent, 20)
        XCTAssertEqual(try XCTUnwrap(draft.profile).heightCm, 176)
    }

    func testNewUserNeedsMissingHeightAndWeightAndCanEditPrefills() throws {
        var draft = OnboardingDraft(saved: nil, healthHeightCm: nil, healthWeightKg: nil,
                                    healthEstimateProfile: nil)
        XCTAssertNil(draft.profile)
        draft.height = "175"
        XCTAssertNil(draft.profile)
        draft.weight = " 80,5 "
        let profile = try XCTUnwrap(draft.profile)
        XCTAssertEqual(profile.weightKg, 80.5)
        XCTAssertEqual(profile.estimateProfile, "neutral")
        XCTAssertEqual(profile.deficitPercent, 10)
        draft.estimateProfile = "female"
        XCTAssertEqual(draft.profile?.estimateProfile, "female")
        draft.height = "nan"
        XCTAssertNil(draft.profile)
    }
}
