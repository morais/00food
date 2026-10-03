import SwiftUI

struct ReviewEstimationView: View {
    @Environment(FoodStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let estimation: PendingEstimation
    @State private var name = ""
    @State private var serving = ""
    @State private var kcal = ""
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Agent estimate") {
                    TextField("Food", text: $name)
                    TextField("Serving", text: $serving)
                    HStack {
                        TextField("Calories", text: $kcal).keyboardType(.numberPad)
                        Text("kcal").foregroundStyle(.secondary)
                    }
                    if let note = estimation.agentNote, !note.isEmpty {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Save food & log it") { save() }
                        .frame(maxWidth: .infinity).disabled(busy || !valid)
                    Button("Discard estimate", role: .destructive) { discard() }
                        .frame(maxWidth: .infinity).disabled(busy)
                } footer: {
                    Text("Saved foods appear in Log again for one-tap use. The photo is deleted after review.")
                }
            }
            .navigationTitle("Review estimate")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .onAppear {
                name = estimation.proposedName ?? ""
                serving = estimation.proposedServing ?? ""
                kcal = estimation.proposedKcal.map(String.init) ?? ""
            }
            .alert("Could not save estimate", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !serving.trimmingCharacters(in: .whitespaces).isEmpty &&
        (1...5000).contains(Int(kcal) ?? 0)
    }

    private func save() {
        guard let value = Int(kcal) else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                if name != estimation.proposedName || serving != estimation.proposedServing || value != estimation.proposedKcal {
                    try await store.updateProposal(id: estimation.id, name: name, serving: serving, kcal: value)
                }
                try await store.accept(estimation)
                dismiss()
            } catch { errorText = error.localizedDescription }
        }
    }

    private func discard() {
        busy = true
        Task {
            defer { busy = false }
            do { try await store.deleteEstimation(estimation); dismiss() }
            catch { errorText = error.localizedDescription }
        }
    }
}
