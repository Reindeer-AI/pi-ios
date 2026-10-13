import PiWidgetLayout
import SwiftUI

/// An extension's panel in a sheet: its page or component, with a Close button (closing tells the extension, as
/// Escape would in pi's terminal).
struct PanelSheet: View {
    let panel: AppModel.Panel
    let sessionTitle: String?
    let onEvent: ([String: Any]) -> Void
    let close: () -> Void

    var body: some View {
        NavigationStack {
            PanelWebView(content: panel.content, extensionName: panel.extensionName, messages: panel.messages, scrolls: true, onEvent: onEvent)
                .ignoresSafeArea(.container, edges: .bottom)
                .background(background)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text(panel.title ?? panel.extensionName).font(.headline).lineLimit(1)
                            Text([panel.title == nil ? nil : panel.extensionName, sessionTitle].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) { Button("Close", action: close) }
                }
        }
        .presentationDetents([.medium, .large])
    }

    /// Views sit on grouped rows; a page has the plain background unless it sets its own.
    private var background: Color {
        if case .view = panel.content { Color(.systemGroupedBackground) } else { Color(.systemBackground) }
    }
}

/// An extension's panel above the message box, as tall as its content up to a limit, then scrolling.
struct PanelWidget: View {
    let panel: AppModel.Panel
    let onEvent: ([String: Any]) -> Void
    @State private var height: CGFloat = 0
    private let maxHeight: CGFloat = 220

    var body: some View {
        PanelWebView(content: panel.content, extensionName: panel.extensionName, messages: panel.messages, scrolls: height > maxHeight, compact: true,
                     onEvent: onEvent, onHeight: { height = $0 })
            .frame(height: min(max(height, 1), maxHeight))
    }
}

/// The agent's `show_html` card in the chat: its page as tall as its content up to a limit, and in a sheet on demand.
/// A page's `pi.prompt(text)` (after a tap) sends the text as the user's next message.
struct HTMLCard: View {
    let title: String
    let html: String
    let prompt: (String) -> Void
    private let callId: String
    @State private var height: CGFloat
    @State private var expanded = false
    private static let maxHeight: CGFloat = 520
    /// Heights pages last reported, so a card scrolled back into the chat keeps its size while it reloads.
    private static var heights: [String: CGFloat] = [:]

    init(callId: String, title: String, html: String, prompt: @escaping (String) -> Void) {
        self.callId = callId
        self.title = title
        self.html = html
        self.prompt = prompt
        _height = State(initialValue: Self.heights[callId] ?? 160)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.caption.bold())
                    .foregroundStyle(.tint)
                    .frame(width: 24, height: 24)
                    .background(.tint.opacity(0.14), in: .rect(cornerRadius: 6))
                Text(title).font(.subheadline.bold()).lineLimit(1)
                Spacer(minLength: 4)
                Button("Expand", systemImage: "arrow.up.left.and.arrow.down.right") { expanded = true }
                    .labelStyle(.iconOnly).font(.caption)
            }
            .padding(10)
            PanelWebView(content: .html(html), scrolls: height > Self.maxHeight, onEvent: handle, onHeight: { value in
                height = value
                Self.heights[callId] = value
            })
            .frame(height: min(max(height, 44), Self.maxHeight))
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(.rect(cornerRadius: 12))
        .sheet(isPresented: $expanded) {
            NavigationStack {
                PanelWebView(content: .html(html), scrolls: true, onEvent: handle)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .background(Color(.systemBackground))
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { expanded = false } } }
            }
        }
    }

    private func handle(_ event: [String: Any]) {
        guard event["type"] as? String == "prompt", let text = event["text"] as? String, !text.isEmpty else { return }
        expanded = false
        prompt(text)
    }
}

// MARK: - Apps

/// An app's symbol: its SF Symbol, or a generic one for a name iOS doesn't have.
func appSymbol(_ name: String?) -> String {
    guard let name, UIImage(systemName: name) != nil else { return "app" }
    return name
}

/// An app's page in a sheet. Minimize (or swiping the sheet away) puts it in the session's dock with its page still
/// running; Close in the menu ends it.
struct AppSheet: View {
    let panel: AppModel.Panel
    let title: String
    let sessionTitle: String?
    let minimize: () -> Void
    let close: () -> Void
    /// Back to the sessions list, the app still open (`AppModel.showSessions`).
    let sessions: () -> Void
    @State private var detent: PresentationDetent = .large
    @State private var addingToHomeScreen = false

    var body: some View {
        NavigationStack {
            Group {
                if let page = panel.page { AppPageView(page: page) }
            }
            .overlay { if !panel.pageReady { ProgressView() } }
            .ignoresSafeArea(.container, edges: .bottom)
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sessions", systemImage: "chevron.backward", action: sessions)
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Label(title, systemImage: appSymbol(panel.app?.icon)).labelStyle(.titleAndIcon).font(.headline).lineLimit(1)
                        Text([panel.extensionName, sessionTitle].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Minimize", systemImage: "chevron.down", action: minimize)
                    Menu {
                        Button("Add to Home Screen…", systemImage: "plus.square.on.square") { addingToHomeScreen = true }
                        Button("Close App", systemImage: "xmark", role: .destructive, action: close)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("App menu")
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .sheet(isPresented: $addingToHomeScreen) {
            AddToHomeScreenSheet(title: title, icon: panel.app?.icon, widgetApp: HomeScreenWidgets.app(for: panel))
        }
    }
}

/// An app's page on a wide screen (an iPad), in place of a sheet: beside the session, or expanded across the whole
/// screen (Expand and Collapse switch between them, with the same running page).
struct AppColumn: View {
    let panel: AppModel.Panel
    let title: String
    let minimize: () -> Void
    let close: () -> Void
    var expanded = false
    var setExpanded: (Bool) -> Void = { _ in }
    /// Expanded: back to the sessions list, the app beside its session again.
    var sessions: (() -> Void)?
    @State private var addingToHomeScreen = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                if expanded, let sessions {
                    Button("Sessions", systemImage: "chevron.backward", action: sessions).labelStyle(.iconOnly)
                }
                Label(title, systemImage: appSymbol(panel.app?.icon)).labelStyle(.titleAndIcon).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                Button(expanded ? "Collapse" : "Expand",
                       systemImage: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    setExpanded(!expanded)
                }
                .labelStyle(.iconOnly)
                Menu {
                    Button("Add to Home Screen…", systemImage: "plus.square.on.square") { addingToHomeScreen = true }
                    Button("Close App", systemImage: "xmark", role: .destructive, action: close)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("App menu")
                Button("Minimize", systemImage: expanded ? "chevron.down" : "sidebar.trailing", action: minimize).labelStyle(.iconOnly)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            Divider()
            if let page = panel.page {
                AppPageView(page: page).overlay { if !panel.pageReady { ProgressView() } }
            }
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: $addingToHomeScreen) {
            AddToHomeScreenSheet(title: title, icon: panel.app?.icon, widgetApp: HomeScreenWidgets.app(for: panel))
        }
    }
}

/// The session's running apps, above the message box: tap one to open it, hold it to close it.
struct AppDock: View {
    let apps: [AppModel.DockApp]
    let open: (AppModel.DockApp) -> Void
    let close: (AppModel.DockApp) -> Void
    /// Shares the app's extension (`SharedExtension.swift`).
    var share: ((AppModel.DockApp) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(apps) { app in
                    Button { open(app) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: appSymbol(app.icon)).font(.caption.bold()).foregroundStyle(.tint)
                            Text(app.title).font(.subheadline.weight(.medium)).lineLimit(1)
                            if let badge = app.badge {
                                Text(badge)
                                    .font(.caption2.bold().monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.red, in: .capsule)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color(.secondarySystemBackground), in: .capsule)
                        .overlay(Capsule().strokeBorder(app.visible ? Color.accentColor : .clear, lineWidth: 1.5))
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if let share { Button("Share \(app.title)…", systemImage: "square.and.arrow.up") { share(app) } }
                        Button("Close \(app.title)", systemImage: "xmark", role: .destructive) { close(app) }
                    }
                    .accessibilityLabel("\(app.title)\(app.badge.map { ", \($0)" } ?? ""). Open app")
                }
            }
        }
        .scrollClipDisabled()
    }
}
