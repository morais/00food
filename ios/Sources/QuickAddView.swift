import PhotosUI
import SwiftUI
import UIKit

struct QuickAddView: View {
    private enum FoodTab: String, CaseIterable {
        case saved = "Your foods"
        case new = "New food"
    }

    var openCameraOnAppear = false
    @Environment(FoodStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedTab: FoodTab = .saved
    @State private var descriptionText = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var loadingPhoto = false
    @State private var photoLoadID = UUID()
    @State private var showingCamera = false
    @State private var didOpenCamera = false
    @State private var showingManual = false
    @State private var editingPortions: FoodItem?
    @State private var busy = false
    @State private var errorText: String?
    @FocusState private var searchFocused: Bool

    private var matches: [FoodItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty ? Array(store.recentFoods.prefix(25)) : store.foods.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Log food mode", selection: $selectedTab) {
                    ForEach(FoodTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
                List {
                    if selectedTab == .saved {
                        Section {
                            TextField("Search your foods", text: $query)
                                .focused($searchFocused)
                                .submitLabel(.search)
                        }
                        if !matches.isEmpty {
                            Section(query.isEmpty ? "Most used · one tap to log" : "Matching foods · one tap to log") {
                                ForEach(matches) { food in
                                    Button { log(food) } label: { foodRow(food) }
                                        .disabled(busy)
                                        .swipeActions(edge: .trailing) {
                                            Button("5 a day", systemImage: "leaf") { editingPortions = food }
                                        }
                                        .contextMenu {
                                            Button("Set fruit & veg portions") { editingPortions = food }
                                        }
                                }
                            }
                        } else {
                            Section {
                                Text(query.isEmpty ? "Your saved foods will appear here after you log one." :
                                     "No saved food matches your search.")
                                    .foregroundStyle(.secondary)
                                Button(query.isEmpty ? "Add your first food" : "Add \"\(query)\" as new food") {
                                    selectedTab = .new
                                }
                            }
                        }
                    } else {
                        Section("Ask your agent") {
                            TextField("Describe food and portion", text: $descriptionText)
                                .submitLabel(.done)
                            HStack(spacing: 12) {
                                PhotosPicker(selection: $photoItem, matching: .images) {
                                    Label("Photos", systemImage: "photo.on.rectangle")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                    Button { photoItem = nil; showingCamera = true } label: {
                                        Label("Camera", systemImage: "camera")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            if let photoData, let image = UIImage(data: photoData) {
                                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .accessibilityLabel("Photo attached to this food")
                                Button("Remove photo", role: .destructive) {
                                    self.photoData = nil
                                    photoItem = nil
                                }
                            }
                            if loadingPhoto { ProgressView("Preparing photo…") }
                            Button { requestEstimate() } label: {
                                HStack {
                                    Spacer()
                                    if busy { ProgressView().tint(.white) }
                                    else { Image(systemName: "sparkles") }
                                    Text(busy ? "Sending to your agent…" : "Ask my agent to estimate")
                                        .fontWeight(.semibold)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(!canRequestEstimate)
                            Text("Your agent receives the description and attached photo together, then you review its estimate before logging.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Section {
                            Button { showingManual = true } label: {
                                Label("Enter calories myself", systemImage: "pencil")
                            }
                            .disabled(busy)
                        } header: {
                            Text("Manual entry")
                        }
                    }
                }
            }
            .navigationTitle("Log food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showingCamera) { CameraPicker { image in setPhoto(image) } }
            .task {
                guard openCameraOnAppear && !didOpenCamera else { return }
                didOpenCamera = true
                selectedTab = .new
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { showingCamera = true }
            }
            .sheet(isPresented: $showingManual) {
                ManualFoodView(initialName: descriptionText.isEmpty ? query : descriptionText) { dismiss() }
            }
            .sheet(item: $editingPortions) { FruitVegPortionsView(food: $0) }
            .onChange(of: selectedTab) { _, tab in
                searchFocused = false
                if tab == .new && descriptionText.isEmpty {
                    descriptionText = query.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            .onChange(of: photoItem) { _, item in
                let loadID = UUID()
                photoLoadID = loadID
                guard let item else { loadingPhoto = false; return }
                loadingPhoto = true
                Task {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self),
                              let image = UIImage(data: data) else {
                            throw FoodServiceError(message: "This photo could not be opened. Try another one.")
                        }
                        if photoLoadID == loadID { setPhoto(image) }
                    } catch { if photoLoadID == loadID { errorText = error.localizedDescription } }
                    if photoLoadID == loadID { loadingPhoto = false }
                }
            }
            .alert("Could not log food", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private var canRequestEstimate: Bool {
        !busy && !loadingPhoto &&
            (!descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photoData != nil)
    }

    private func foodRow(_ food: FoodItem) -> some View {
        HStack {
            Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text(food.name).foregroundStyle(.primary)
                Text(food.serving).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text("\(food.kcal) kcal").foregroundStyle(.secondary)
                if food.countedFruitVegPortions > 0 {
                    Label("\(food.countedFruitVegPortions)", systemImage: "leaf.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            }
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

    private func requestEstimate() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await store.requestEstimate(description: descriptionText.trimmingCharacters(in: .whitespacesAndNewlines),
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
    @State private var fruitVegPortions = 0
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
                Picker("Fruit & veg portions", selection: $fruitVegPortions) {
                    ForEach(0...5, id: \.self) { Text("\($0)").tag($0) }
                }
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
                let food = try await store.createFood(name: name, serving: serving, kcal: value,
                                                      fruitVegPortions: fruitVegPortions)
                try await store.log(food)
                dismiss()
                onSaved()
            } catch { errorText = error.localizedDescription }
        }
    }
}

private struct FruitVegPortionsView: View {
    @Environment(FoodStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let food: FoodItem
    @State private var portions = 0
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(food.name).font(.headline)
                    Picker("Fruit & veg portions per serving", selection: $portions) {
                        ForEach(0...5, id: \.self) { Text("\($0)").tag($0) }
                    }
                } footer: {
                    Text("A rough count is enough. Updating this food also corrects its earlier logs.")
                }
            }
            .navigationTitle("5 a day")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        do { try store.setFruitVegPortions(portions, for: food); dismiss() }
                        catch { errorText = error.localizedDescription }
                    }
                }
            }
            .onAppear { portions = food.countedFruitVegPortions }
            .alert("Could not update food", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
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
