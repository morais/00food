import PhotosUI
import SwiftUI
import UIKit

struct QuickAddView: View {
    @Environment(FoodStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var showingCamera = false
    @State private var showingManual = false
    @State private var busy = false
    @State private var errorText: String?
    @FocusState private var searchFocused: Bool

    private var matches: [FoodItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty ? Array(store.recentFoods.prefix(25)) : store.recentFoods.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
        }
    }
    private var seeds: [SeedFood] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return SeedFood.all.filter { seed in
            (needle.isEmpty || seed.name.localizedCaseInsensitiveContains(needle)) &&
            !store.foods.contains { $0.name.localizedCaseInsensitiveCompare(seed.name) == .orderedSame }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Search or describe a food", text: $query, axis: .vertical)
                        .focused($searchFocused)
                        .submitLabel(.search)
                }
                if let photoData, let image = UIImage(data: photoData) {
                    Section("Photo to estimate") {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        Button("Remove photo", role: .destructive) { self.photoData = nil }
                    }
                }
                if !matches.isEmpty {
                    Section("Your foods · one tap to log") {
                        ForEach(matches) { food in
                            Button { log(food) } label: { foodRow(food.name, food.serving, food.kcal) }
                                .disabled(busy)
                        }
                    }
                }
                if !seeds.isEmpty {
                    Section("Common starting points") {
                        ForEach(seeds) { seed in
                            Button { logSeed(seed) } label: { foodRow(seed.name, seed.serving, seed.kcal) }
                                .disabled(busy)
                        }
                    }
                }
                Section("Something new") {
                    HStack {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label("Choose photo", systemImage: "photo")
                        }
                        Spacer()
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button { showingCamera = true } label: { Label("Camera", systemImage: "camera") }
                        }
                    }
                    Button { requestEstimate() } label: {
                        Label("Ask my agent to estimate", systemImage: "sparkles")
                    }
                    .disabled(busy || (query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photoData == nil))
                    Text("Your connected agent can review text or a photo. You approve its estimate before it is saved and logged.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button { showingManual = true } label: {
                        Label("Enter calories myself", systemImage: "pencil")
                    }
                    .disabled(busy)
                }
            }
            .navigationTitle("Log food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showingCamera) { CameraPicker { image in setPhoto(image) } }
            .sheet(isPresented: $showingManual) {
                ManualFoodView(initialName: query) { dismiss() }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    do {
                        if let data = try await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) { setPhoto(image) }
                    } catch { errorText = error.localizedDescription }
                }
            }
            .alert("Could not log food", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private func foodRow(_ name: String, _ serving: String, _ kcal: Int) -> some View {
        HStack {
            Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text(name).foregroundStyle(.primary)
                Text(serving).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(kcal) kcal").foregroundStyle(.secondary)
        }
    }

    private func log(_ food: FoodItem, quantity: Double = 1) {
        busy = true
        Task {
            defer { busy = false }
            do { try await store.log(food, quantity: quantity); dismiss() }
            catch { errorText = error.localizedDescription }
        }
    }

    private func logSeed(_ seed: SeedFood) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let food = try await store.createFood(name: seed.name, serving: seed.serving,
                                                      kcal: seed.kcal, source: "seed")
                try await store.log(food)
                dismiss()
            } catch { errorText = error.localizedDescription }
        }
    }

    private func requestEstimate() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await store.requestEstimate(description: query.trimmingCharacters(in: .whitespacesAndNewlines),
                                                photo: photoData)
                dismiss()
            } catch { errorText = error.localizedDescription }
        }
    }

    private func setPhoto(_ image: UIImage) {
        if let data = Self.jpeg(image) { photoData = data }
        else { errorText = "This photo could not be prepared. Try a different image." }
    }

    private static func jpeg(_ image: UIImage) -> Data? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        for maxWidth: CGFloat in [1200, 900, 650] {
            let width = min(image.size.width, maxWidth)
            let height = image.size.height * width / image.size.width
            let resized = UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { _ in
                image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            for quality in [0.65, 0.4, 0.25] {
                if let data = resized.jpegData(compressionQuality: quality), data.count <= 2_000_000 {
                    return data
                }
            }
        }
        return nil
    }
}

struct ManualFoodView: View {
    @Environment(FoodStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var name: String
    @State private var serving = "1 serving"
    @State private var kcal = ""
    @State private var busy = false
    @State private var errorText: String?
    var onSaved: () -> Void

    init(initialName: String, onSaved: @escaping () -> Void = {}) {
        _name = State(initialValue: initialName)
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Food name", text: $name)
                TextField("Serving (for example, 1 bowl)", text: $serving)
                TextField("Calories per serving", text: $kcal).keyboardType(.numberPad)
                Text("A rough value is enough. Once saved, this food is one tap away next time.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("New food")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save & log") { save() }
                        .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  serving.trimmingCharacters(in: .whitespaces).isEmpty || Int(kcal) == nil)
                }
            }
            .alert("Could not save food", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private func save() {
        guard let value = Int(kcal), (1...5000).contains(value) else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let food = try await store.createFood(name: name, serving: serving, kcal: value)
                try await store.log(food)
                dismiss()
                onSaved()
            } catch { errorText = error.localizedDescription }
        }
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    var onPhoto: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPhoto: onPhoto, dismiss: dismiss) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onPhoto: (UIImage) -> Void
        let dismiss: DismissAction
        init(onPhoto: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onPhoto = onPhoto; self.dismiss = dismiss
        }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onPhoto(image) }
            dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { dismiss() }
    }
}
