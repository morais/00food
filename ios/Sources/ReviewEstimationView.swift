import SwiftUI

struct ReviewEstimationView: View {
    @Environment(FoodStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let estimation: PendingEstimation
    @State private var name = ""
    @State private var serving = ""
    @State private var kcal = ""
    @State private var fruitVegPortions = 0
    @State private var clarification = ""
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Food to estimate") {
                    Text(current.description.isEmpty ? "Photo attached" : current.description)
                    if current.hasPhoto { Label("Photo attached", systemImage: "photo") }
                }
                if current.state == "proposed" {
                    Section("Agent estimate") {
                        TextField("Food", text: $name)
                        TextField("Serving", text: $serving)
                        HStack {
                            TextField("Calories", text: $kcal).keyboardType(.numberPad)
                            Text("kcal").foregroundStyle(.secondary)
                        }
                        Picker("Fruit & veg portions", selection: $fruitVegPortions) {
                            ForEach(0...5, id: \.self) { Text("\($0)").tag($0) }
                        }
                        if let note = current.agentNote, !note.isEmpty {
                            Text(note).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section {
                        Text(current.state == "uploading" ? "Saved on your iPhone; sends when online." :
                             "Waiting for your connected agent to estimate this food.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let reasoning = current.reasoning, !reasoning.isEmpty {
                    Section("Why this calorie estimate") { Text(reasoning) }
                }
                Section {
                    if let previous = current.clarification, !previous.isEmpty {
                        Text("Last clarification: \(previous)").font(.footnote).foregroundStyle(.secondary)
                    }
                    TextField("Add portion or ingredient details", text: $clarification, axis: .vertical)
                        .lineLimit(2...4)
                    Button("Send clarification") { sendClarification() }
                        .disabled(busy || clarification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Clarify for the agent")
                } footer: {
                    Text("Your agent will receive an event and can make a new estimate.")
                }
                Section {
                    if current.state == "proposed" {
                        Button("Save food & log it") { save() }
                            .frame(maxWidth: .infinity).disabled(busy || !valid)
                    }
                    Button("Discard estimate", role: .destructive) { discard() }
                        .frame(maxWidth: .infinity).disabled(busy)
                } footer: {
                    Text("Saved foods appear in Log again for one-tap use. The photo is deleted after review.")
                }
            }
            .navigationTitle(current.state == "proposed" ? "Review estimate" : "Food estimate")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .onAppear {
                name = estimation.proposedName ?? ""
                serving = estimation.proposedServing ?? ""
                kcal = estimation.proposedKcal.map(String.init) ?? ""
                fruitVegPortions = estimation.proposedFruitVegPortions ?? 0
            }
            .onChange(of: current.updatedAt) { _, _ in
                name = current.proposedName ?? ""
                serving = current.proposedServing ?? ""
                kcal = current.proposedKcal.map(String.init) ?? ""
                fruitVegPortions = current.proposedFruitVegPortions ?? 0
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

    private var current: PendingEstimation {
        store.estimations.first(where: { $0.id == estimation.id }) ?? estimation
    }

    private func sendClarification() {
        do {
            try store.clarifyEstimate(id: estimation.id, text: clarification)
            clarification = ""
        } catch { errorText = error.localizedDescription }
    }

    private func save() {
        guard let value = Int(kcal) else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                if name != current.proposedName || serving != current.proposedServing || value != current.proposedKcal ||
                    fruitVegPortions != (current.proposedFruitVegPortions ?? 0) {
                    try await store.updateProposal(id: estimation.id, name: name, serving: serving, kcal: value,
                                                   fruitVegPortions: fruitVegPortions)
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
