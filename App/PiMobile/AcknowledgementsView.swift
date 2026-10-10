import SwiftUI

/// Settings → About → Acknowledgements: the license of everything pi ships, from Acknowledgements.json
/// (scripts/acknowledgements.mjs writes it).
struct AcknowledgementsView: View {
    struct Item: Decodable, Identifiable, Hashable {
        let name: String
        let version: String?
        let license: String
        let text: String
        var id: String { "\(name)@\(version ?? "")" }
    }

    struct Section: Decodable, Identifiable {
        let title: String
        let items: [Item]
        var id: String { title }
    }

    private struct File: Decodable {
        let sections: [Section]
        let texts: [String: String]
    }

    @State private var file: File?
    @State private var search = ""

    var body: some View {
        List {
            if let file {
                ForEach(file.sections) { section in
                    let items = section.items.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
                    if !items.isEmpty {
                        SwiftUI.Section(section.title) {
                            ForEach(items) { item in
                                NavigationLink {
                                    LicenseText(item: item, text: file.texts[item.text] ?? "")
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.version.map { "\(item.name) \($0)" } ?? item.name)
                                        Text(item.license).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Acknowledgements")
        .searchable(text: $search)
        .task {
            guard file == nil, let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "json"),
                  let data = try? Data(contentsOf: url) else { return }
            file = try? JSONDecoder().decode(File.self, from: data)
        }
    }
}

private struct LicenseText: View {
    let item: AcknowledgementsView.Item
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
