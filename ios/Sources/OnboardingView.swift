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
            if let profile = draft.profile {
                PaceSelectionView(profile: profile, deficitPercent: $draft.deficitPercent,
                                  firstDay: store.accountStartedAt ?? Calendar.current.startOfDay(for: Date()),
                                  saveTitle: "Continue",
                                  onBack: { step = skippedEssentials ? .welcome : .essentials },
                                  onCancel: store.profile == nil ? nil : onCompleted) { updated in
                    try await store.saveProfile(updated)
                    step = .agent
                }
            }
        case .agent:
            AgentSetupView(onCompleted: onCompleted)
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
                            permission("Weight", icon: "scalemass",
                                detail: "Uses your latest reading for progress and a fallback estimate when resting energy isn't available. You can also log your weight manually.")
                            permission("Body fat", icon: "chart.xyaxis.line",
                                detail: "Adds body-fat readings to your progress chart. This is optional.")
                            permission("Biological sex", icon: "person.fill",
                                detail: "Prefills the optional setting for the fallback calorie estimate and ACE body-fat reference lines.")
                            permission("Food calories", icon: "fork.knife",
                                detail: "Optional export writes new food logs as Dietary Energy so Apple Health can show your food calorie totals. Permission is requested when you enable export.")
                            permission("Water", icon: "drop.fill",
                                detail: "Shows your recorded water intake and progress toward your daily goal.")
                        }
                        Text("The next sheet asks for read access. Write access is requested separately: water when you log a glass, weight when you log it manually, and food calories when you enable export.")
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
                    Text("Used for progress and the fallback estimate. This value is saved to your account; you can connect a scale or log weight manually later.")
                }
                Section {
                    Picker("Estimate setting", selection: $draft.estimateProfile) {
                        Text("Neutral").tag("neutral")
                        Text("Female").tag("female")
                        Text("Male").tag("male")
                    }
                } header: { Text("Optional") } footer: {
                    Text("Adjusts the fallback estimate and ACE body-fat reference lines.")
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
