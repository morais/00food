import SwiftUI

struct InfoDisclosure: View {
    let title: String
    let message: String
    var linkTitle: String? = nil
    var linkURL: URL? = nil
    var sources: [HealthSource] = []
    @State private var showingInfo = false

    var body: some View {
        Button { showingInfo = true } label: {
            Image(systemName: "info.circle")
                .font(.body)
                .frame(minWidth: 30, minHeight: 30)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .popover(isPresented: $showingInfo) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title).font(.headline)
                    Text(message).font(.subheadline)
                    if let linkTitle, let linkURL {
                        Link(linkTitle, destination: linkURL).font(.subheadline).foregroundStyle(.tint)
                    }
                    if !sources.isEmpty { HealthSourceLinks(sources: sources) }
                }
                .textCase(nil)
                .foregroundStyle(.primary)
                .padding(18)
            }
            .frame(idealWidth: 300, maxWidth: 340, idealHeight: 260, maxHeight: 420)
            .presentationCompactAdaptation(.popover)
        }
    }
}
