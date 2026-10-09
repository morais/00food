import SwiftUI

struct PaceSelectionView: View {
    let profile: FoodProfile
    @Binding var deficitPercent: Int
    let firstDay: Date
    let saveTitle: String
    var onBack: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    let onSave: (FoodProfile) async throws -> Void
    @State private var saving = false
    @State private var errorText: String?

    private var previewProfile: FoodProfile {
        var preview = profile
        preview.deficitPercent = deficitPercent
        return preview
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(DeficitLevel.allCases) { level in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { deficitPercent = level.rawValue }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(level.title).font(.headline)
                                        Spacer(minLength: 4)
                                        Image(systemName: deficitPercent == level.rawValue ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(deficitPercent == level.rawValue ? Color.accentColor : Color.secondary)
                                    }
                                    Text("\(level.rawValue)% deficit").font(.subheadline).foregroundStyle(.secondary)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(.primary)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16)
                                        .strokeBorder(deficitPercent == level.rawValue ? Color.accentColor : .clear, lineWidth: 2)
                                }
                            }
                            .buttonStyle(.plain).disabled(saving)
                            .accessibilityAddTraits(deficitPercent == level.rawValue ? [.isSelected] : [])
                        }
                    }
                    PlanProjectionCard(profile: previewProfile, firstDay: firstDay)
                    Text("Your allowance is resting plus active energy, reduced by this percentage, including exercise. You can change your pace anytime in Progress & plans.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button { save() } label: {
                        HStack {
                            Spacer()
                            if saving { ProgressView().tint(.white) }
                            Text(saveTitle).fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(saving)
                }
                .padding(20)
            }
            .navigationTitle("Choose your pace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onBack {
                    ToolbarItem(placement: .topBarLeading) { Button("Back", action: onBack).disabled(saving) }
                    if let onCancel {
                        ToolbarItem(placement: .topBarTrailing) { Button("Cancel", action: onCancel).disabled(saving) }
                    }
                } else if let onCancel {
                    ToolbarItem(placement: .topBarLeading) { Button("Cancel", action: onCancel).disabled(saving) }
                }
            }
            .alert("Could not save your plan", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private func save() {
        guard !saving else { return }
        let selected = previewProfile
        saving = true
        Task {
            defer { saving = false }
            do { try await onSave(selected) }
            catch { errorText = error.localizedDescription }
        }
    }
}
