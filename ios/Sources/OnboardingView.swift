import SwiftUI

struct OnboardingView: View {
    var onCompleted: () -> Void = {}
    @Environment(FoodStore.self) private var store
    @Environment(HealthEnergy.self) private var health
    @State private var step = OnboardingStep.welcome
    @State private var skippedEssentials = false
    @State private var draft = OnboardingDraft(saved: nil, healthHeightCm: nil,
                                               healthWeightKg: nil, healthEstimateProfile: nil)
    @State private var connecting = false

    var body: some View {
        switch step {
        case .essentials:
            OnboardingDetailsView(draft: $draft, onBack: { step = .welcome },
                                  onContinue: { step = .pace }, onCancel: onCompleted)
        case .pace:
            OnboardingPaceView(draft: $draft,
                               onBack: { step = skippedEssentials ? .welcome : .essentials },
                               onEditDetails: { skippedEssentials = false; step = .essentials },
                               onCompleted: onCompleted)
        case .welcome:
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Let your tracker do the measuring.").font(.title2.bold())
                        Text("00Food works best with Apple Watch or another tracker that syncs energy to Apple Health. You choose which readings to share.")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 16) {
                            permission("Active energy", icon: "figure.walk",
                                detail: "Combines your movement and resting energy before applying your plan’s percentage deficit, including exercise.")
                            permission("Resting energy", icon: "heart.fill",
                                detail: "Uses recent completed days to estimate your baseline calorie budget.")
                            permission("Height", icon: "ruler",
                                detail: "Prefills your details and sets the healthy BMI range shown in your weight chart.")
                            permission("Biological sex", icon: "person.fill",
                                detail: "Prefills the optional setting for the fallback calorie estimate and ACE body-fat reference lines. Adult BMI ranges are the same for all sexes. You can change the setting or use Neutral.")
                            permission("Weight", icon: "scalemass",
                                detail: "Uses your latest reading for progress and a fallback estimate when resting energy isn't available.")
                            permission("Body fat", icon: "chart.xyaxis.line",
                                detail: "Adds body-fat readings to your progress chart. This is optional.")
                            permission("Water", icon: "drop.fill",
                                detail: "Shows your recorded water intake and progress toward your daily goal.")
                        }
                        Text("The next sheet asks to read these values. Writing water is requested when you log a glass; writing weight when you log it to Health. Writing food calories is an optional setting.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("Your details and latest weight are saved to your account. Other Health history stays on this device unless you request a daily review.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let error = health.errorMessage {
                            Text(error).font(.footnote).foregroundStyle(.orange)
                        }
                        Button {
                            connecting = true
                            Task {
                                await health.connect()
                                connecting = false
                                if health.errorMessage == nil { continueAfterHealth() }
                            }
                        } label: {
                            HStack {
                                Spacer()
                                if connecting { ProgressView().tint(.white) }
                                Text(connecting ? "Connecting…" : "Connect Apple Health").fontWeight(.semibold)
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(connecting || !health.available)
                        Button("Continue without Health") {
                            draft = OnboardingDraft(saved: store.profile, healthHeightCm: nil,
                                                    healthWeightKg: nil, healthEstimateProfile: nil)
                            skippedEssentials = false
                            step = .essentials
                        }
                            .frame(maxWidth: .infinity).disabled(connecting)
                    }
                    .padding(20)
                }
                .navigationTitle("Welcome to 00Food")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if store.profile != nil {
                        ToolbarItem(placement: .topBarTrailing) { Button("Cancel", action: onCompleted).disabled(connecting) }
                    }
                }
                .onAppear { health.setHistoryStart(store.accountStartedAt) }
            }
        }
    }

    private func continueAfterHealth() {
        draft = OnboardingDraft(saved: store.profile, healthHeightCm: health.latestHeightCm,
                                healthWeightKg: health.usableLatestWeightKg,
                                healthEstimateProfile: health.healthEstimateProfile)
        step = OnboardingStep.afterHealth(heightCm: health.latestHeightCm,
                                          weightKg: health.usableLatestWeightKg)
        skippedEssentials = step == .pace
    }

    private func permission(_ title: String, icon: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(.blue).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

private struct OnboardingDetailsView: View {
    @Binding var draft: OnboardingDraft
    let onBack: () -> Void
    let onContinue: () -> Void
    let onCancel: () -> Void
    @Environment(FoodStore.self) private var store
    @Environment(HealthEnergy.self) private var health

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Height in cm", text: $draft.height).keyboardType(.decimalPad)
                } header: { Text("Height") } footer: {
                    Text("Used for your BMI progress range and the fallback resting estimate. You can edit any Health prefill.")
                }
                Section {
                    TextField("Weight in kg", text: $draft.weight).keyboardType(.decimalPad)
                } header: { Text("Weight") } footer: {
                    Text("Used for progress and the fallback estimate. This value is saved to your account; you can connect a scale or log a Health weight later.")
                }
                Section {
                    Picker("Estimate setting", selection: $draft.estimateProfile) {
                        Text("Neutral").tag("neutral")
                        Text("Female").tag("female")
                        Text("Male").tag("male")
                    }
                } header: { Text("Optional") } footer: {
                    Text("Adjusts the fallback estimate and ACE body-fat reference lines. Adult BMI ranges do not depend on sex. You can keep Neutral or change this later.")
                }
                Section {
                    Button("Continue") { onContinue() }
                        .fontWeight(.semibold).frame(maxWidth: .infinity)
                        .buttonStyle(.borderedProminent).disabled(draft.profile == nil)
                }
            }
            .navigationTitle("Just the essentials")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Back", action: onBack) }
                if store.profile != nil {
                    ToolbarItem(placement: .topBarTrailing) { Button("Cancel", action: onCancel) }
                }
            }
        }
    }
}

private struct OnboardingPaceView: View {
    @Binding var draft: OnboardingDraft
    let onBack: () -> Void
    let onEditDetails: () -> Void
    let onCompleted: () -> Void
    @Environment(FoodStore.self) private var store
    @State private var saving = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(DeficitLevel.allCases) { level in
                        Button {
                            draft.deficitPercent = level.rawValue
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(level.title).font(.headline)
                                    Text("\(level.rawValue)% deficit · \(100 - level.rawValue)% of your energy")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: draft.deficitPercent == level.rawValue ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(draft.deficitPercent == level.rawValue ? Color.accentColor : Color.secondary)
                            }
                            .foregroundStyle(.primary).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(saving)
                        .accessibilityAddTraits(draft.deficitPercent == level.rawValue ? [.isSelected] : [])
                    }
                } header: { Text("Your pace") } footer: {
                    Text("Your allowance is resting plus active energy, reduced by this percentage—including exercise. You can change your pace anytime in Progress & plans.")
                }
                if let profile = draft.profile {
                    Section {
                        Text("\(profile.heightCm.formatted(.number.precision(.fractionLength(1)))) cm · \(profile.weightKg.formatted(.number.precision(.fractionLength(1)))) kg")
                        Text("\(profile.estimateProfile.capitalized) estimate setting")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Edit details", action: onEditDetails).disabled(saving)
                    } header: { Text("Your details") } footer: {
                        Text("Resting energy uses recent completed Health days when available. The fallback estimate uses these details and a reference age of 35.")
                    }
                }
                Section {
                    Button { save() } label: {
                        HStack {
                            Spacer()
                            if saving { ProgressView() }
                            Text("Start logging").fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent).disabled(saving || draft.profile == nil)
                }
            }
            .navigationTitle("Choose your pace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Back", action: onBack).disabled(saving) }
                if store.profile != nil {
                    ToolbarItem(placement: .topBarTrailing) { Button("Cancel", action: onCompleted).disabled(saving) }
                }
            }
            .alert("Could not finish setup", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private func save() {
        guard !saving, let profile = draft.profile else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await store.saveProfile(profile)
                onCompleted()
            } catch { errorText = error.localizedDescription }
        }
    }
}
