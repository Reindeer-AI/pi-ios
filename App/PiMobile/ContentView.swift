import PhotosUI
import PiEngineKit
import SafariServices
import SwiftUI

struct RootView: View {
    @Bindable var app: AppModel
    /// The open session, and sessions opened from it (forks): the stack on a phone; on a wide screen the last one is the
    /// session beside the list.
    @State private var path: [Int] = []
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// `-openSettings YES` opens Settings at launch (for tests).
    @State private var showingSettings = UserDefaults.standard.bool(forKey: "openSettings")
    /// Whether the extension sheet (dialogs and sheet panels) is up; it stays up between the dialogs of one command.
    @State private var showingDialogs = false
    /// Whether the sheet last showed an app, which leaves at once when minimized (no wait for a next dialog).
    @State private var sheetShowsApp = false
    /// On a wide screen: whether the sessions list shows, and the screen's width (an app beside a session on a narrower
    /// one puts the list away, so the session keeps room).
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var width: CGFloat = 0
    private var openSessionShowsApp: Bool {
        guard let id = path.last else { return false }
        return app.panels.contains { $0.sessionId == id && $0.app != nil && $0.visible }
    }

    /// The panel in the sheet: on a wide screen apps show beside their session instead (`AppColumn`).
    private var sheetPanel: AppModel.Panel? {
        app.panels.first { $0.placement == "sheet" && $0.visible && !(sizeClass == .regular && $0.app != nil) }
    }

    private var hasExtensionSheet: Bool { !app.dialogs.isEmpty || sheetPanel != nil }

    var body: some View {
        Group {
            if sizeClass == .regular { split } else { stack }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // A shortcut's session.
        .onChange(of: app.requestedSession) { _, id in
            guard let id else { return }
            path = [id]
            app.requestedSession = nil
        }
        // An app's Sessions button: the list (beside the session on a wide screen).
        .onChange(of: app.sessionsRequested) {
            if sizeClass == .regular { withAnimation { columns = .all } } else { path.removeAll() }
        }
        // An app beside the session takes the list's room on a narrower iPad, which gets it back when the app closes or
        // minimizes (this layout has no sidebar button to bring it back).
        .onChange(of: openSessionShowsApp) { _, shows in
            if sizeClass == .regular, width < 1200 { withAnimation { columns = shows ? .detailOnly : .all } }
        }
        // A session deleted while open: nothing is open.
        .onChange(of: app.sessions.map(\.id)) { _, ids in
            if let open = path.last, app.phase == .ready, !ids.contains(open) { path.removeAll { !ids.contains($0) } }
        }
        .sheet(isPresented: $showingSettings) { SettingsView(app: app) }
        // A device's first sync, when it differs from what's in iCloud: which settings to keep.
        .sheet(isPresented: Binding(get: { !SyncedSettings.shared.conflicts.isEmpty }, set: { _ in })) {
            SyncChoiceSheet(conflicts: SyncedSettings.shared.conflicts) { SyncedSettings.shared.resolve(useICloud: $0) }
                .interactiveDismissDisabled()
        }
        // A login started from Settings presents its sheet from Settings (only the top screen can present one).
        .sheet(isPresented: Binding(get: { app.authFlow != nil && !showingSettings }, set: { if !$0 { app.cancelLogin() } })) {
            AuthSheet(app: app)
        }
        // Extension dialogs, then sheet panels, from any session, one at a time in one sheet; swiping it away answers
        // the dialog with nothing, closes the panel, or minimizes the app to its session's dock.
        .sheet(isPresented: Binding(get: { showingDialogs }, set: { shown in
            if !shown {
                if let dialog = app.dialogs.first { app.respond(to: dialog, with: nil) }
                else if let panel = sheetPanel { panel.app == nil ? app.dismiss(panel) : app.minimize(panel) }
            }
            showingDialogs = shown
        })) {
            if let dialog = app.dialogs.first {
                ExtensionDialogView(dialog: dialog, sessionTitle: app.sessions.first { $0.id == dialog.sessionId }?.title) { value in
                    app.respond(to: dialog, with: value)
                }
                .id(dialog.id)
            } else if let panel = sheetPanel, panel.app != nil {
                AppSheet(panel: panel, title: app.title(of: panel), sessionTitle: app.sessions.first { $0.id == panel.sessionId }?.title,
                         minimize: { app.minimize(panel) }, close: { app.dismiss(panel) },
                         sessions: { app.showSessions(leaving: panel, wide: false) })
                    .id(panel.id)
            } else if let panel = sheetPanel {
                PanelSheet(panel: panel, sessionTitle: app.sessions.first { $0.id == panel.sessionId }?.title,
                           onEvent: { app.panelEvent($0, panelId: panel.id) }, close: { app.dismiss(panel) })
                    .id(panel.id)
            } else {
                ProgressView().presentationDetents([.medium])
            }
        }
        .onChange(of: sheetPanel?.id) { _, _ in
            if let panel = sheetPanel { sheetShowsApp = panel.app != nil }
        }
        .onChange(of: hasExtensionSheet) { _, shown in
            if shown {
                showingDialogs = true
            } else if sheetShowsApp {
                // A minimized app leaves at once.
                showingDialogs = false
            } else {
                // A command often asks again right away: keep the sheet up briefly for its next dialog.
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    if !hasExtensionSheet { showingDialogs = false }
                }
            }
        }
        // A shared extension (a .piext file from AirDrop, Messages, Files…): asks before adding it.
        .onOpenURL { app.openShared($0) }
        .sheet(item: $app.sharedExtension) { offer in SharedExtensionSheet(app: app, offer: offer) }
        .sheet(item: $app.sharedSession) { offer in SharedSessionSheet(app: app, offer: offer) }
        // `-openSession ID` (automated runs): opens that session.
        .onAppear {
            if UserDefaults.standard.object(forKey: "openSession") != nil { path = [UserDefaults.standard.integer(forKey: "openSession")] }
        }
        .tint(Color("AccentColor"))
        // The engine's and the browsers' web views must stay in the window for WebKit to keep their pages running.
        .background(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                EngineHostView(engine: app.engine)
                BrowserParkingView()
                AppParkingView()
            }
        }
    }
}

extension RootView {
    /// A phone: the sessions, and a session pushed over them.
    private var stack: some View {
        NavigationStack(path: $path) {
            SessionsView(app: app, path: $path, showingSettings: $showingSettings)
                .navigationDestination(for: Int.self) { id in SessionView(app: app, id: id, path: $path) }
        }
    }

    /// An iPad (or any wide screen): the sessions in a sidebar, the open one beside them.
    private var split: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SessionsView(app: app, path: $path, showingSettings: $showingSettings,
                         selection: Binding(get: { path.last }, set: { path = $0.map { [$0] } ?? [] }))
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 440)
        } detail: {
            NavigationStack {
                if let id = path.last {
                    SessionView(app: app, id: id, path: $path).id(id)
                } else if app.sessions.isEmpty {
                    // The list says what to do.
                    Logo(size: 72).opacity(0.35)
                } else {
                    ContentUnavailableView {
                        VStack(spacing: 14) {
                            Logo(size: 72)
                            Text("No session open").font(.title2.bold())
                        }
                    } description: {
                        Text("Choose a session, or start a new one.")
                    }
                }
            }
        }
    }
}

// MARK: - Sessions

private struct SessionsView: View {
    @Bindable var app: AppModel
    @Binding var path: [Int]
    @Binding var showingSettings: Bool
    /// On a wide screen, the session open beside the list; on a phone the list pushes instead.
    var selection: Binding<Int?>? = nil
    @State private var error: String?
    @State private var address = ""
    @State private var browsing: BrowserSession?
    @State private var cleanup: Cleanup?

    /// What "Clean Up" would delete: sessions not used for a while, or all of them.
    enum Cleanup: Identifiable, CaseIterable {
        case day, week, month, all
        var id: Self { self }

        var label: String {
            switch self {
            case .day: "Not used for a day"
            case .week: "Not used for a week"
            case .month: "Not used for a month"
            case .all: "All sessions"
            }
        }

        var cutoff: Date? {
            switch self {
            case .day: Date.now.addingTimeInterval(-86_400)
            case .week: Date.now.addingTimeInterval(-7 * 86_400)
            case .month: Date.now.addingTimeInterval(-30 * 86_400)
            case .all: nil
            }
        }
    }

    var body: some View {
        List(selection: selection) {
            if case .failed(let message) = app.phase {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search or enter website", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.webSearch)
                        .submitLabel(.go)
                        .onSubmit(openAddress)
                }
            }
            ForEach(app.sessions) { session in
                NavigationLink(value: session.id) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.title).font(.headline).lineLimit(1)
                            Text("\(app.subtitle(of: session)) · \(session.lastActive, format: .relative(presentation: .named))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        // Its running apps (as far as this launch has looked).
                        if let running = app.apps[session.id]?.running, !running.isEmpty {
                            HStack(spacing: 5) {
                                ForEach(running.prefix(3)) { docked in
                                    Image(systemName: appSymbol(docked.icon)).font(.caption).foregroundStyle(.tint)
                                }
                            }
                            .accessibilityLabel("Apps: \(running.map(\.title).joined(separator: ", "))")
                        }
                        if session.running { WorkingIndicator(label: nil) }
                    }
                }
            }
            .onDelete { offsets in
                let ids = offsets.map { app.sessions[$0].id }
                Task { for id in ids { await app.delete(id) } }
            }
        }
        .overlay {
            if app.sessions.isEmpty, app.phase == .ready {
                ContentUnavailableView {
                    VStack(spacing: 14) {
                        Logo(size: 84)
                        Text("No sessions").font(.title2.bold())
                    }
                } description: {
                    Text(app.defaultModel == nil
                         ? "Add a model in Settings: sign in to a provider, download an on-device model, or connect a server."
                         : "Each session is its own pi agent with its own workspace.")
                } actions: {
                    Button("New session") { newSession() }.buttonStyle(.borderedProminent).disabled(app.defaultModel == nil)
                }
            }
        }
        .navigationTitle("pi")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Clean Up", systemImage: "trash") {
                    Section("Delete sessions") {
                        ForEach(Cleanup.allCases) { option in
                            let count = app.idleSessions(since: option.cutoff).count
                            Button("\(option.label) (\(count))", role: .destructive) { cleanup = option }
                                .disabled(count == 0)
                        }
                    }
                }
                .disabled(app.sessions.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New session", systemImage: "square.and.pencil") { newSession() }
                    .disabled(app.phase != .ready || app.defaultModel == nil)
            }
        }
        .confirmationDialog(cleanupTitle, isPresented: Binding(get: { cleanup != nil }, set: { if !$0 { cleanup = nil } }), titleVisibility: .visible) {
            if let cleanup {
                let ids = app.idleSessions(since: cleanup.cutoff).map(\.id)
                Button("Delete \(ids.count) \(ids.count == 1 ? "session" : "sessions")", role: .destructive) {
                    Task { await app.delete(ids) }
                }
            }
        } message: {
            Text("Their conversations and workspace files are deleted, and their Crabbox machines released. Running sessions are kept.")
        }
        .fullScreenCover(item: $browsing) { browser in
            BrowserScreen(browser: browser, profileName: app.browser.profiles.name(of: browser.profileKey) ?? "")
        }
        .alert("Cannot create session", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    private var cleanupTitle: String {
        guard let cleanup else { return "" }
        return cleanup == .all ? "Delete all sessions?" : "Delete sessions \(cleanup.label.lowercased())?"
    }

    /// Opens what was typed in the user's own browser on the default profile.
    private func openAddress() {
        let browser = app.browser.standaloneBrowser(for: app.browser.profiles.defaultKey)
        browser.open(address)
        address = ""
        browsing = browser
    }

    private func newSession() {
        Task {
            do {
                path.append(try await app.createSession())
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Session

private struct SessionView: View {
    @Bindable var app: AppModel
    let id: Int
    @Binding var path: [Int]
    @State private var prompt = ""
    @State private var showingModels = false
    @State private var renaming = false
    @State private var title = ""
    @State private var showingBrowser = false
    @State private var dictation = Dictation()
    @FocusState private var composing: Bool
    /// Files to go with the next message (picked, or dropped on the session).
    @State private var attachments: [StagedFile] = []
    @State private var importingFiles = false
    @State private var pickingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    /// Whether the message wraps past one line: the buttons beside it then go two by two, leaving it the width.
    @State private var messageWraps = false
    /// The message's length when it wrapped. Two by two, the buttons widen the box, so the text may fit on one line
    /// again; they stay so until the message is shorter than this (a keystroke, never the layout itself, sets them back),
    /// or the layout would flip back and forth without end.
    @State private var wrappedAt = 0
    /// The accessories' own height (browser card, widgets, status lines), for the strip that holds them.
    @State private var accessoriesHeight: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// An app's extension being shared (from its dock entry).
    @State private var sharing: SharedFile?
    /// A message open for selecting part of its text (its menu's Select Text).
    @State private var selecting: SelectableText?
    /// Whether the transcript keeps up with new output: until the reader scrolls up, and again once they're back at
    /// the end (or send a message, or tap the arrow).
    @State private var following = true
    /// Whether the end of the transcript is in view.
    @State private var atEnd = true

    private var session: AppModel.Session? { app.sessions.first { $0.id == id } }
    private var browser: BrowserSession? { app.browser.sessions[id] }
    /// The session's running apps, for the dock.
    private var dock: [AppModel.DockApp] { app.apps[id]?.running ?? [] }
    /// On a wide screen, the session's app on screen shows in a column beside it, or expanded across the screen.
    private var columnApp: AppModel.Panel? {
        sizeClass == .regular ? app.panels.first { $0.sessionId == id && $0.app != nil && $0.visible && !$0.expanded } : nil
    }
    private var expandedApp: AppModel.Panel? {
        sizeClass == .regular ? app.panels.first { $0.sessionId == id && $0.app != nil && $0.visible && $0.expanded } : nil
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let session {
                        ForEach(session.items) { item in
                            TranscriptRow(item: item, items: session.items) { text in
                                following = true
                                Task { await app.send(text, to: id) }
                            }
                                .contextMenu {
                                    if let text = item.copyableText {
                                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                                        Button("Select Text", systemImage: "selection.pin.in.out") { selecting = SelectableText(text: text) }
                                    }
                                    Button("Fork from Here", systemImage: "arrow.triangle.branch") { fork(at: item.id) }
                                }
                        }
                        if let draft = session.draft {
                            AssistantText(text: draft.text, thinking: draft.thinking, streaming: true)
                        }
                        ForEach(session.tools) { tool in
                            ToolCard(name: tool.name, arguments: tool.arguments, output: tool.output, isError: false, running: true)
                        }
                        if session.compacting {
                            WorkingIndicator(label: "Compacting context")
                        } else if session.running, session.draft == nil, session.tools.isEmpty {
                            WorkingIndicator(label: "Working")
                        }
                        if let error = session.error {
                            Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
                // On a wide screen, a column of readable width.
                .frame(maxWidth: Self.readableWidth)
                .frame(maxWidth: .infinity)
            }
            // Opens at the end, and a short transcript sits at the bottom. Followed, the end stays in view as the transcript
            // or the space for it changes (the keyboard); otherwise the transcript keeps the reader's place.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .defaultScrollAnchor(following ? .bottom : nil, for: .sizeChanges)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height - geometry.contentInsets.bottom >= geometry.contentSize.height - 40
            } action: { _, isAtEnd in
                atEnd = isAtEnd
            }
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .interacting: following = false
                case .idle where atEnd: following = true
                default: break
                }
            }
            .overlay(alignment: .bottom) {
                if !following, !atEnd {
                    Button {
                        following = true
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.body.weight(.semibold))
                            .frame(width: 40, height: 40)
                            .background(.regularMaterial, in: Circle())
                            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Scroll to the End")
                    .padding(.bottom, 8)
                    .transition(.opacity)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            // Files dropped on the session (from Files, Photos, another app beside pi) go with the next message.
            .dropDestination(for: DroppedFile.self) { files, _ in
                attachments.append(contentsOf: files.map(\.staged))
                return !files.isEmpty
            }
            .overlay {
                if let session, session.loaded, session.items.isEmpty, !session.running {
                    SessionWelcome { prompt = $0 }
                }
            }
            .onChange(of: session?.items.count) { if following { proxy.scrollTo("bottom") } }
            .onChange(of: session?.draft?.text) { if following { proxy.scrollTo("bottom") } }
            .overlay(alignment: .top) {
                if let notice = session?.notice {
                    NoticeBanner(notice: notice)
                        .padding(.horizontal)
                        .task(id: notice.date) {
                            try? await Task.sleep(for: .seconds(5))
                            app.clearNotice(id)
                        }
                }
            }
            .onChange(of: session?.tools.last?.output) { if following { proxy.scrollTo("bottom") } }
        }
        .safeAreaInset(edge: .bottom) { composer }
        // Inside the toolbar's view (an inspector outside it takes the session's toolbar away in a split view).
        .inspector(isPresented: Binding(get: { columnApp != nil }, set: { shown in
            if !shown, let panel = columnApp { app.minimize(panel) }
        })) {
            if let panel = columnApp {
                AppColumn(panel: panel, title: app.title(of: panel), minimize: { app.minimize(panel) }, close: { app.dismiss(panel) },
                          setExpanded: { app.setExpanded(panel, $0) })
                    .inspectorColumnWidth(min: 320, ideal: 420, max: 600)
            }
        }
        .fullScreenCover(item: Binding(get: { expandedApp }, set: { panel in
            if panel == nil, let open = expandedApp { app.minimize(open) }
        })) { panel in
            AppColumn(panel: panel, title: app.title(of: panel), minimize: { app.minimize(panel) }, close: { app.dismiss(panel) },
                      expanded: true, setExpanded: { app.setExpanded(panel, $0) },
                      sessions: { app.showSessions(leaving: panel, wide: true) })
        }
        .onDisappear { dictation.stop() }
        .navigationTitle(session?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { showingModels = true } label: {
                    VStack(spacing: 0) {
                        Text(session?.title ?? "").font(.headline).lineLimit(1)
                        Text(session.map(app.subtitle(of:)) ?? "").font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Change model", systemImage: "cpu") { showingModels = true }
                    // How much the model thinks, from the levels it takes (none to choose for one that doesn't reason).
                    if let session, app.thinkingLevels(of: session.model).count > 1 {
                        Picker(selection: Binding(
                            get: { session.thinkingLevel },
                            set: { level in Task { await app.setThinkingLevel(level, for: id) } }
                        )) {
                            ForEach(app.thinkingLevels(of: session.model), id: \.self) { level in
                                Text(AppModel.thinkingTitle(level)).tag(level)
                            }
                        } label: {
                            Label("Thinking", systemImage: "brain")
                        }
                        .pickerStyle(.menu)
                    }
                    Picker(selection: Binding(
                        get: { session?.browser ?? "" },
                        set: { key in Task { await app.setBrowser(key.isEmpty ? nil : key, for: id) } }
                    )) {
                        ForEach(app.browser.profiles.profiles) { profile in Text(profile.name).tag(profile.key) }
                        Text("Private").tag(BrowserProfiles.privateKey)
                        if session?.browser == nil { Text("None").tag("") }
                    } label: {
                        Label("Browser", systemImage: "globe")
                    }
                    .pickerStyle(.menu)
                    Button("Rename", systemImage: "pencil") {
                        title = session?.title ?? ""
                        renaming = true
                    }
                    // The whole session as a file: its history, settings and workspace, to open on another phone.
                    Button("Share Session…", systemImage: "square.and.arrow.up") {
                        Task {
                            do { sharing = SharedFile(url: try await app.shareSessionFile(id)) } catch { log("error", "[\(id)] share session: \(error.localizedDescription)") }
                        }
                    }
                    // The apps the session's extensions offer.
                    if let available = app.apps[id]?.available, !available.isEmpty {
                        Menu {
                            ForEach(available) { offered in
                                Button(offered.title, systemImage: UIImage(systemName: offered.icon ?? "") == nil ? "app" : offered.icon!) {
                                    app.openApp(offered.key, in: id)
                                }
                            }
                        } label: {
                            Label("Apps", systemImage: "square.grid.2x2")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task(id: id) {
            await app.loadApps(id)
            app.reopenApps(in: id)
        }
        .sheet(item: $sharing) { file in ShareSheet(url: file.url).presentationDetents([.medium, .large]) }
        .sheet(item: $selecting) { selectable in SelectTextSheet(text: selectable.text) }
        // A run may have added an extension with apps.
        .onChange(of: session?.running) { _, running in
            if running == false { Task { await app.loadApps(id) } }
        }
        .sheet(isPresented: $showingModels) {
            ModelPicker(app: app, selection: session?.model) { model in
                Task { await app.setModel(model, for: id) }
            }
        }
        .fullScreenCover(isPresented: $showingBrowser) {
            if let browser {
                BrowserScreen(browser: browser, profileName: app.browser.profiles.name(of: browser.profileKey) ?? "")
            }
        }
        .alert("Rename session", isPresented: $renaming) {
            TextField("Title", text: $title)
            Button("Save") { Task { await app.rename(id, to: title) } }
            Button("Cancel", role: .cancel) {}
        }
        // Again once the session is listed (a session opened while the app starts is not yet).
        .task(id: session == nil) { await app.loadTranscript(id) }
        .onChange(of: prompt.hasPrefix("/")) { _, typingCommand in
            if typingCommand { Task { await app.loadCommands(id) } }
        }
        .onChange(of: session?.editorText) { _, value in
            if let value { prompt = value.append ? prompt + value.text : value.text }
        }
    }

    /// Commands matching what is typed after "/", until the command name is complete.
    private var commandSuggestions: [AppModel.Command] {
        guard prompt.hasPrefix("/"), !prompt.contains(" "), let session else { return [] }
        let typed = prompt.dropFirst().lowercased()
        return Array(session.commands.filter { typed.isEmpty || $0.name.lowercased().hasPrefix(typed) }.prefix(6))
    }

    private var composer: some View {
        VStack(spacing: 8) {
            // What shows above the message box, in one scroll view whether typing or not (so widgets keep their state),
            // exactly as tall as its content: while typing at most a short strip, so a tall widget cannot push the box
            // and its Send button under the keyboard. (A scroll view takes all the height it may, hence the measuring.)
            if hasAccessories {
                ScrollView {
                    VStack(spacing: 8) { accessories }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { accessoriesHeight = $0 }
                }
                .frame(height: composing ? min(accessoriesHeight, 110) : accessoriesHeight)
                .scrollDisabled(!composing || accessoriesHeight <= 110)
                .scrollBounceBehavior(.basedOnSize)
            }
            if !commandSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(commandSuggestions) { command in
                        Button { prompt = "/\(command.name) " } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("/\(command.name)").font(.callout.monospaced())
                                if let description = command.description {
                                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
            }
            if let error = dictation.error {
                Label(error, systemImage: "mic.slash").font(.caption).foregroundStyle(.red)
            }
            if !attachments.isEmpty {
                StagedFiles(files: $attachments).padding(.bottom, 6)
            }
            messageField
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: Self.readableWidth)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// The transcript's and the message box's width at most, for a wide screen.
    static let readableWidth: CGFloat = 820

    private var hasAccessories: Bool {
        !dock.isEmpty
            || browser.map { !$0.tabs.isEmpty } == true
            || app.panels.contains { $0.sessionId == id && $0.placement == "widget" }
            || session.map { !$0.widgets.isEmpty || !$0.statuses.isEmpty } == true
    }

    /// The app dock, the browser card, extension panels, widgets, and status lines.
    @ViewBuilder private var accessories: some View {
        if !dock.isEmpty {
            AppDock(apps: dock, open: { app.openApp($0.key, in: id) }, close: { app.closeApp($0.key, in: id) }, share: { docked in
                Task {
                    do {
                        sharing = SharedFile(url: try await app.shareFile(extension: docked.extensionName, sessionId: id))
                    } catch {
                        log("error", "share \(docked.extensionName): \(error.localizedDescription)")
                    }
                }
            })
        }
        if let browser, !browser.tabs.isEmpty {
            BrowserCard(browser: browser, profileName: app.browser.profiles.name(of: browser.profileKey) ?? "") {
                showingBrowser = true
            }
        }
        ForEach(app.panels.filter { $0.sessionId == id && $0.placement == "widget" }) { panel in
            PanelWidget(panel: panel) { app.panelEvent($0, panelId: panel.id) }
        }
        if let session, !session.widgets.isEmpty || !session.statuses.isEmpty {
            ExtensionStatus(statuses: session.statuses, widgets: session.widgets)
        }
    }

    private var canSend: Bool { !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    private func send() {
        send(.steer)
    }

    /// While the agent works, a message steers it (after its current tool call) or waits for the run to end.
    private func send(_ delivery: AppModel.Delivery) {
        dictation.stop()
        var text = prompt
        // Attached files go into the session's workspace; the message names them for the model.
        if !attachments.isEmpty {
            do {
                let paths = try app.attach(attachments.map(\.url), to: id)
                text = [text.trimmingCharacters(in: .whitespacesAndNewlines), Attachments.lines(paths)].filter { !$0.isEmpty }.joined(separator: "\n\n")
                attachments = []
            } catch {
                log("error", "[\(id)] attach: \(error.localizedDescription)")
                return
            }
        }
        prompt = ""
        following = true
        Task { await app.send(text, to: id, delivery: delivery) }
    }

    /// Picked files and photos, copied aside until the message is sent.
    private func stage(_ files: [URL]) {
        for file in files {
            do { attachments.append(try StagedFile.copy(of: file)) } catch { log("error", "[\(id)] attach \(file.lastPathComponent): \(error.localizedDescription)") }
        }
    }

    private func stage(_ items: [PhotosPickerItem]) async {
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            // As a JPEG (pi's read tool takes JPEG, PNG, GIF and WebP, not HEIC).
            let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.9) ?? data
            let stamp = Date.now.formatted(Date.VerbatimFormatStyle(
                format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) at \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
                timeZone: .current, calendar: .current))
            if let file = try? StagedFile.write(jpeg, named: "Photo \(stamp)\(items.count > 1 ? " \(index + 1)" : "").jpg") { attachments.append(file) }
        }
    }

    private var messageField: some View {
        HStack(alignment: .bottom) {
            ComposerButtons(square: messageWraps) {
                // While typing: put the keyboard away (the composer's Send stays above the keyboard).
                if composing {
                    Button("Hide keyboard", systemImage: "keyboard.chevron.compact.down") { composing = false }
                        .labelStyle(.iconOnly).font(.title3).foregroundStyle(.secondary)
                }
                if let session, let usage = session.context, usage.tokens > 0 {
                    ContextGauge(usage: usage, compacting: session.compacting, running: session.running) {
                        Task { await app.compact(id) }
                    }
                }
                // Files for the agent: into the session's workspace, named in the message.
                Menu {
                    Button("Files…", systemImage: "folder") { importingFiles = true }
                    Button("Photos…", systemImage: "photo.on.rectangle") { pickingPhotos = true }
                } label: {
                    Image(systemName: "paperclip").font(.title3)
                }
                .accessibilityLabel("Attach")
                .foregroundStyle(.secondary)
                // Dictation with iOS's speech recognition; tap again to stop.
                Button(dictation.listening ? "Stop dictation" : "Dictate", systemImage: dictation.listening ? "mic.fill" : "mic") {
                    if dictation.listening {
                        dictation.stop()
                    } else {
                        Task { await dictation.start(after: prompt) { prompt = $0 } }
                    }
                }
                .labelStyle(.iconOnly).font(.title2)
                .foregroundStyle(dictation.listening ? .red : .secondary)
                .symbolEffect(.pulse, isActive: dictation.listening)
            }
            .padding(.bottom, 6)
            .animation(.snappy, value: messageWraps)
            .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let files) = result { stage(files) }
            }
            .photosPicker(isPresented: $pickingPhotos, selection: $photoItems, matching: .images, preferredItemEncoding: .compatible)
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    await stage(items)
                    photoItems = []
                }
            }
            TextField(dictation.listening ? "Listening…" : session?.running == true ? "Steer pi" : "Message pi", text: $prompt, axis: .vertical)
                .lineLimit(1...6)
                .focused($composing)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
                .onGeometryChange(for: Bool.self) { $0.size.height > 48 } action: { tall in
                    if tall, !messageWraps {
                        wrappedAt = prompt.count
                        messageWraps = true
                    }
                }
                .onChange(of: prompt) { _, text in
                    // Shorter than when it wrapped: back to one row (where, if it still wraps, it goes two by two again).
                    if messageWraps, text.count < wrappedAt { messageWraps = false }
                }
            if session?.running == true {
                Button("Stop", systemImage: "stop.circle.fill") { app.abort(id) }
                    .labelStyle(.iconOnly).font(.title).tint(.red)
                // Steer the run in progress; hold for "after this run".
                if canSend {
                    Menu {
                        Button("Steer now", systemImage: "arrow.turn.down.right") { send(.steer) }
                        Button("Send after this run", systemImage: "text.badge.plus") { send(.followUp) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title)
                    } primaryAction: {
                        send(.steer)
                    }
                    .accessibilityLabel("Steer")
                }
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                    .labelStyle(.iconOnly).font(.title)
                    .disabled(!canSend)
            }
        }
    }

    /// Forks the session at an entry and opens the fork.
    private func fork(at entryId: Int) {
        Task {
            do {
                if let fork = try await app.fork(id, at: entryId) { path.append(fork) }
            } catch {
                log("error", "[\(id)] fork: \(error.localizedDescription)")
            }
        }
    }
}

/// What a session's extensions show above the composer: text widgets, then their status lines.
private struct ExtensionStatus: View {
    let statuses: [String: String]
    let widgets: [String: [String]]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(widgets.keys.sorted(), id: \.self) { key in
                Text(widgets[key]?.joined(separator: "\n") ?? "").font(.caption.monospaced())
            }
            if !statuses.isEmpty {
                Text(statuses.keys.sorted().compactMap { statuses[$0] }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An extension's notification (pi's `ctx.ui.notify`), shown for a few seconds.
private struct NoticeBanner: View {
    let notice: AppModel.Notice

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.extensionName).font(.caption2).foregroundStyle(.secondary)
                Text(notice.message).font(.footnote)
            }
        } icon: {
            Image(systemName: notice.level == "error" ? "exclamationmark.octagon.fill"
                  : notice.level == "warning" ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(notice.level == "error" ? .red : notice.level == "warning" ? .orange : .accentColor)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// A dialog an extension shows: pick an option, confirm, or enter text.
private struct ExtensionDialogView: View {
    let dialog: AppModel.ExtensionDialog
    let sessionTitle: String?
    let answer: (String?) -> Void
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                if let details {
                    Section { Text(details).font(heading.isEmpty ? .headline : .callout) }
                }
                if let message = dialog.message, !message.isEmpty {
                    Section { Text(message) }
                }
                switch dialog.kind {
                case "select":
                    Section {
                        ForEach(dialog.options, id: \.self) { option in Button(option) { answer(option) } }
                    }
                case "confirm":
                    Section {
                        Button("Yes") { answer("yes") }
                        Button("No", role: .cancel) { answer(nil) }
                    }
                case "editor":
                    Section { TextEditor(text: $text).font(.body.monospaced()).frame(minHeight: 220) }
                default:
                    Section {
                        TextField(dialog.placeholder ?? "", text: $text, axis: .vertical).onSubmit { answer(text) }
                    }
                }
                Section {
                    Text("From \(dialog.extensionName)\(sessionTitle.map { " in \($0)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(heading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { answer(nil) } }
                if dialog.kind == "input" || dialog.kind == "editor" {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { answer(text) } }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { text = dialog.prefill ?? "" }
    }

    /// A short title heads the dialog. A long one (a question, say), and the lines after the first (a report), show in
    /// the dialog itself.
    private var heading: String {
        let first = String(dialog.title.prefix { $0 != "\n" })
        return first.count <= 30 ? first : ""
    }

    private var details: String? {
        let rest = (heading.isEmpty ? dialog.title : String(dialog.title.drop { $0 != "\n" }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }
}

private struct TranscriptRow: View {
    let item: TranscriptItem
    let items: [TranscriptItem]
    /// Sends a message to the session (from a `show_html` card).
    let prompt: (String) -> Void

    var body: some View {
        switch item {
        case .user(_, let text):
            let message = Attachments.split(text)
            VStack(alignment: .trailing, spacing: 6) {
                if !message.text.isEmpty {
                    Text(message.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.tint.opacity(0.16), in: .rect(cornerRadius: 18))
                        .textSelection(.enabled)
                }
                ForEach(message.paths, id: \.self) { path in AttachmentLabel(path: path) }
            }
            .padding(.leading, 48)
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant(_, let text, let thinking, _, let error):
            VStack(alignment: .leading, spacing: 6) {
                AssistantText(text: text, thinking: thinking, streaming: false)
                if let error { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red) }
            }
        case .tool(_, let toolCallId, "show_html", _, false):
            let page = htmlCard(for: toolCallId)
            HTMLCard(callId: toolCallId, title: page.title, html: page.html, prompt: prompt)
        case .tool(_, let toolCallId, let toolName, let output, let isError):
            ToolCard(name: toolName, arguments: arguments(for: toolCallId), output: output, isError: isError, running: false)
        case .custom(_, let customType, let text):
            VStack(alignment: .leading, spacing: 4) {
                Label(customType, systemImage: "puzzlepiece.extension").font(.caption).foregroundStyle(.secondary)
                MarkdownText(text: text)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.08), in: .rect(cornerRadius: 12))
        case .bash(_, let command, let output, let exitCode):
            ToolCard(name: "bash", arguments: TranscriptItem.arguments(["command": command]), output: output,
                     isError: (exitCode ?? 0) != 0, running: false)
        case .compaction(_, let summary, let reason):
            CompactionRow(summary: summary, reason: reason)
        }
    }

    /// A `show_html` card's title and page, from the call.
    private func htmlCard(for toolCallId: String) -> (title: String, html: String) {
        let object = arguments(for: toolCallId).data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        return (object["title"] as? String ?? "", object["html"] as? String ?? "")
    }

    /// The call's arguments live on the assistant message that requested it.
    private func arguments(for toolCallId: String) -> String {
        for item in items {
            if case .assistant(_, _, _, let calls, _) = item, let call = calls.first(where: { $0.id == toolCallId }) {
                return call.arguments
            }
        }
        return ""
    }
}

/// A device's first sync, when its settings differ from what's in iCloud: each setting both have, and which to keep.
private struct SyncChoiceSheet: View {
    let conflicts: [SyncedSettings.Conflict]
    let choose: (_ useICloud: Bool) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(conflict.title).font(.headline)
                            LabeledContent("This device", value: conflict.here).font(.subheadline)
                            LabeledContent("iCloud", value: conflict.iCloud).font(.subheadline)
                        }
                        .padding(.vertical, 2)
                    }
                } footer: {
                    Text("Settings on only one side are kept either way, and lists merge item by item. Your choice decides the ones above, on all your devices.")
                }
                Section {
                    Button("Use iCloud's Settings") { choose(true) }
                    Button("Keep This Device's Settings") { choose(false) }
                }
            }
            .navigationTitle("Your Other Devices")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// The composer's buttons beside the message: in a row, or two by two once the message wraps, so it keeps its width.
private struct ComposerButtons: Layout {
    var square: Bool

    private struct Grid {
        let columns: [CGFloat]
        let rows: [CGFloat]
        let count: Int
        var size: CGSize {
            CGSize(width: columns.reduce(0, +) + 12 * CGFloat(max(columns.count - 1, 0)),
                   height: rows.reduce(0, +) + 8 * CGFloat(max(rows.count - 1, 0)))
        }
    }

    private func grid(_ subviews: Subviews) -> Grid {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let columns = square && sizes.count > 2 ? 2 : max(sizes.count, 1)
        let rows = (sizes.count + columns - 1) / columns
        return Grid(
            columns: (0..<columns).map { column in stride(from: column, to: sizes.count, by: columns).map { sizes[$0].width }.max() ?? 0 },
            rows: (0..<rows).map { row in (row * columns..<min((row + 1) * columns, sizes.count)).map { sizes[$0].height }.max() ?? 0 },
            count: sizes.count
        )
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.isEmpty ? .zero : grid(subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let grid = grid(subviews)
        for (index, subview) in subviews.enumerated() {
            let column = index % grid.columns.count, row = index / grid.columns.count
            let x = bounds.minX + grid.columns[..<column].reduce(0, +) + 12 * CGFloat(column) + grid.columns[column] / 2
            let y = bounds.minY + grid.rows[..<row].reduce(0, +) + 8 * CGFloat(row) + grid.rows[row] / 2
            subview.place(at: CGPoint(x: x, y: y), anchor: .center, proposal: .unspecified)
        }
    }
}

/// Where pi compacted the context: the summary that replaced what came before, folded.
private struct CompactionRow: View {
    let summary: String
    let reason: String

    var body: some View {
        DisclosureGroup {
            MarkdownText(text: summary).font(.footnote).padding(.top, 6)
        } label: {
            Label(title, systemImage: "rectangle.compress.vertical").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.secondary.opacity(0.08), in: .rect(cornerRadius: 12))
    }

    private var title: String {
        switch reason {
        case "threshold": "Context compacted automatically"
        case "overflow": "Context compacted after it overflowed"
        default: "Context compacted"
        }
    }
}

/// How full the session's context is, as a ring by the composer (orange once pi may compact it in the background, red
/// past where it compacts before the next request); tapped, the numbers and Compact Now.
private struct ContextGauge: View {
    let usage: AppModel.ContextUsage
    let compacting: Bool
    let running: Bool
    let compact: () -> Void
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            ZStack {
                Circle().stroke(.secondary.opacity(0.25), lineWidth: 3)
                Circle().trim(from: 0, to: usage.fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if compacting { ProgressView().controlSize(.mini) }
            }
            .frame(width: 22, height: 22)
        }
        .accessibilityLabel("Context")
        .accessibilityValue("\(percent)% used")
        .popover(isPresented: $showing) {
            details.presentationCompactAdaptation(.popover)
        }
    }

    private var percent: Int { Int((usage.fraction * 100).rounded()) }

    private var color: Color {
        guard usage.autoCompact else { return .accentColor }
        if usage.tokens >= usage.threshold { return .red }
        if usage.tokens >= usage.backgroundThreshold { return .orange }
        return .accentColor
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Context").font(.headline)
            if usage.contextWindow > 0 {
                Text("\(usage.tokens.formatted()) of \(usage.contextWindow.formatted()) tokens (\(percent)%)")
                ProgressView(value: usage.fraction).tint(color)
            } else {
                Text("\(usage.tokens.formatted()) tokens")
            }
            if usage.autoCompact {
                Text("pi compacts it automatically at \(usage.threshold.formatted()) tokens (the window less \(usage.reserveTokens.formatted()) for the reply): it summarizes the earlier messages and keeps about the last \(usage.keepRecentTokens.formatted()) tokens as they are.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(compacting ? "Compacting…" : "Compact Now", systemImage: "rectangle.compress.vertical") {
                showing = false
                compact()
            }
            .disabled(compacting || running)
        }
        .padding()
        .frame(width: 300)
    }
}

private struct AssistantText: View {
    let text: String
    let thinking: String
    let streaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !thinking.isEmpty {
                DisclosureGroup("Thinking") {
                    Text(thinking).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if !text.isEmpty {
                MarkdownText(text: text)
            } else if streaming {
                WorkingIndicator(label: "Thinking")
            }
        }
    }
}

/// Assistant markdown: fenced code blocks as code cards, headings in bold, bullets as dots, the rest inline markdown.
private struct MarkdownText: View {
    enum Segment {
        case prose(String)
        case code(language: String, code: String)
        case table(MarkdownTable.Content)
    }

    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.segments(of: text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let prose): Text(Self.inline(prose)).textSelection(.enabled)
                case .code(let language, let code): CodeBlock(language: language, code: code)
                case .table(let table): MarkdownTable(content: table)
                }
            }
        }
    }

    /// Splits on ``` fences; a fence still open while streaming runs to the end.
    static func segments(of text: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var language: String?
        func flushProse() {
            segments += withTables(prose)
            prose = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let open = language {
                    segments.append(.code(language: open, code: code.joined(separator: "\n")))
                    code = []
                    language = nil
                } else {
                    flushProse()
                    language = String(trimmed.dropFirst(3))
                }
            } else if language != nil {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if let language { segments.append(.code(language: language, code: code.joined(separator: "\n"))) }
        flushProse()
        return segments
    }

    /// Prose lines as prose and the tables in them (GitHub's syntax: a header row, a `---` row, then rows; while
    /// streaming, a table shows once its `---` row has arrived).
    static func withTables(_ lines: [Substring]) -> [Segment] {
        var segments: [Segment] = []
        var prose: [Substring] = []
        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { segments.append(.prose(joined)) }
            prose = []
        }
        var index = 0
        while index < lines.count {
            if index + 1 < lines.count, let header = MarkdownTable.cells(of: lines[index]),
               let alignments = MarkdownTable.alignments(of: lines[index + 1]), alignments.count == header.count {
                var rows: [[String]] = []
                index += 2
                while index < lines.count, lines[index].contains("|"), let row = MarkdownTable.cells(of: lines[index]) {
                    rows.append((0..<header.count).map { $0 < row.count ? row[$0] : "" })
                    index += 1
                }
                flushProse()
                segments.append(.table(.init(header: header, alignments: alignments, rows: rows)))
                continue
            }
            prose.append(lines[index])
            index += 1
        }
        flushProse()
        return segments
    }

    static func inline(_ prose: String) -> AttributedString {
        let lines = prose.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.drop { $0 == " " }
            let indent = String(repeating: " ", count: line.count - trimmed.count)
            if let heading = trimmed.firstMatch(of: /^#{1,6} +(.+)$/) { return "**\(heading.1)**" }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return indent + "• " + trimmed.dropFirst(2) }
            return String(line)
        }
        let markdown = lines.joined(separator: "\n")
        return (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(prose)
    }
}

/// A Markdown table as a grid: the header bold on a tinted row, columns aligned as the `---` row says, cells with
/// inline Markdown (bold, code, links). A table wider than the screen scrolls sideways.
private struct MarkdownTable: View {
    struct Content {
        let header: [String]
        let alignments: [TextAlignment]
        let rows: [[String]]
    }

    let content: Content
    /// The header row's height, for the one tinted band behind it.
    @State private var headerHeight: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(content.header.indices, id: \.self) { column in
                        cell(content.header[column], column: column, header: true)
                    }
                }
                ForEach(content.rows.indices, id: \.self) { row in
                    Divider()
                    GridRow {
                        ForEach(content.header.indices, id: \.self) { column in
                            cell(content.rows[row][column], column: column, header: false)
                        }
                    }
                }
            }
            .background(alignment: .top) { Color(.tertiarySystemFill).frame(height: headerHeight) }
            .textSelection(.enabled)
        }
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
        .clipShape(.rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator), lineWidth: 0.5))
    }

    /// A cell wraps past 240 points and fills its column, aligned as its column says.
    private func cell(_ text: String, column: Int, header: Bool) -> some View {
        let alignment = content.alignments[column]
        let frame: Alignment = alignment == .center ? .center : alignment == .trailing ? .trailing : .leading
        return CappedWidth(maxWidth: 240) {
            Text(MarkdownText.inline(text.replacing(/<br\s*\/?>/.ignoresCase(), with: "\n")))
                .font(header ? .subheadline.bold() : .subheadline)
                .multilineTextAlignment(alignment)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: frame)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if header { headerHeight = max(headerHeight, height) }
        }
    }

    /// Text at its natural width up to `maxWidth`, wrapped at that width. It measures the same whatever width it is
    /// offered: the table scrolls sideways, so its cells are first offered no width at all, and text sized that way
    /// reports one line's height, then wraps when placed and overflows its row.
    private struct CappedWidth: Layout {
        let maxWidth: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let text = subviews.first else { return .zero }
            return text.sizeThatFits(ProposedViewSize(width: width(of: text), height: nil))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            guard let text = subviews.first else { return }
            text.place(at: bounds.origin, proposal: ProposedViewSize(width: width(of: text), height: nil))
        }

        private func width(of text: LayoutSubview) -> CGFloat {
            min(text.sizeThatFits(.unspecified).width, maxWidth)
        }
    }

    /// A row's cells, or nil for a line that is not a row. Pipes at the ends are optional; `\|` is a pipe in a cell.
    static func cells(of line: Substring) -> [String]? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in trimmed {
            if escaped {
                current.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// The alignments a `---` row gives its columns (`:--` leading, `:-:` center, `--:` trailing), or nil for another line.
    static func alignments(of line: Substring) -> [TextAlignment]? {
        guard let cells = cells(of: line), !cells.isEmpty else { return nil }
        var alignments: [TextAlignment] = []
        for cell in cells {
            guard cell.wholeMatch(of: /:?-+:?/) != nil else { return nil }
            alignments.append(cell.hasPrefix(":") && cell.hasSuffix(":") ? .center : cell.hasSuffix(":") ? .trailing : .leading)
        }
        return alignments
    }
}

private struct CodeBlock: View {
    let language: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(.caption2.monospaced())
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = code }
                    .labelStyle(.iconOnly).font(.caption)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.footnote.monospaced()).textSelection(.enabled).padding(10)
            }
        }
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
    }
}

/// Animated dots shown while an agent works.
private struct WorkingIndicator: View {
    let label: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "ellipsis")
                .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
                .foregroundStyle(.tint)
            if let label { Text(label).foregroundStyle(.secondary) }
        }
        .font(.footnote.bold())
        .accessibilityLabel(label ?? "Working")
    }
}

/// The empty state of a new session, with prompts to start from.
private struct SessionWelcome: View {
    let choose: (String) -> Void

    private let suggestions = [
        "What can you do on this phone?",
        "Write a Python script that prints the first 20 primes, then run it",
        "Clone https://github.com/earendil-works/pi and summarize its README",
    ]

    var body: some View {
        VStack(spacing: 18) {
            Logo(size: 64)
            VStack(spacing: 4) {
                Text("A new pi agent").font(.title3.bold())
                Text("It has a shell, Python, git, and its own workspace. Runs survive restarts.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button { choose(suggestion) } label: {
                        Text(suggestion).font(.footnote).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 12))
                    .tint(.secondary)
                    .foregroundStyle(.primary)
                }
            }
        }
        .padding(32)
    }
}

/// The app icon, pi with reindeer antlers.
struct Logo: View {
    let size: CGFloat

    var body: some View {
        Image("Logo")
            .resizable()
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: size * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct ToolCard: View {
    let name: String
    let arguments: String
    let output: String
    let isError: Bool
    let running: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.caption.bold())
                        .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                        .frame(width: 24, height: 24)
                        .background(isError ? AnyShapeStyle(.red.opacity(0.14)) : AnyShapeStyle(.tint.opacity(0.14)),
                                    in: .rect(cornerRadius: 6))
                    Text(name).font(.subheadline.bold())
                    Text(summary).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    if running {
                        ProgressView().controlSize(.mini)
                    } else if isError {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).font(.caption)
                    }
                    Image(systemName: "chevron.down").font(.caption2.bold()).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded {
                // The whole call: the command (or arguments), then its output so far.
                if !detail.isEmpty { block(detail) }
                if !output.isEmpty {
                    block(String(output.suffix(4000)))
                } else if running {
                    Text("No output yet").font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
                }
            } else if running, !output.isEmpty {
                // Collapsed while it runs: the last few lines, live.
                block(String(output.suffix(300)))
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
        .animation(.snappy(duration: 0.2), value: expanded)
    }

    private var icon: String {
        switch name {
        case "bash": "terminal"
        case "read": "doc.text"
        case "write": "square.and.pencil"
        case "edit": "pencil.line"
        case let name where name.hasPrefix("browser_"): "globe"
        default: "wrench.and.screwdriver"
        }
    }

    private func block(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(.tertiarySystemBackground), in: .rect(cornerRadius: 8))
            .textSelection(.enabled)
    }

    /// The full command for bash, otherwise the arguments as given (an empty object shows nothing).
    private var detail: String {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return arguments }
        if let command = object["command"] as? String, object.count <= 2 { return command }
        if object.isEmpty { return "" }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? arguments
    }

    /// The command for bash, the path for file tools, otherwise the raw arguments.
    private var summary: String {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return arguments }
        let value = object["command"] ?? object["path"] ?? object["file_path"] ?? object["url"] ?? object["ref"] ?? object["key"]
            ?? object["action"]
        return value.map { "\($0)" } ?? (object.isEmpty ? "" : arguments)
    }
}

// MARK: - Models

private struct ModelPicker: View {
    @Bindable var app: AppModel
    let selection: AppModel.ModelRef?
    let choose: (AppModel.ModelRef) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    /// The providers and models matching the search (by model name or ID, or by provider name: all its models).
    private var shown: [(provider: AppModel.Provider, models: [AppModel.Provider.Model])] {
        let terms = search.lowercased().split(separator: " ").map(String.init)
        return app.usableProviders.compactMap { provider in
            let models = terms.isEmpty ? provider.models : provider.models.filter { model in
                let haystack = "\(provider.name) \(model.name) \(model.id)".lowercased()
                return terms.allSatisfy { haystack.contains($0) }
            }
            return models.isEmpty ? nil : (provider, models)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if app.usableProviders.isEmpty {
                    Text("No models yet. Sign in to a provider, download an on-device model, or connect a server in Settings.")
                        .foregroundStyle(.secondary)
                }
                ForEach(shown, id: \.provider.id) { entry in
                    Section(entry.models.count < entry.provider.models.count
                            ? "\(entry.provider.name) (\(entry.models.count) of \(entry.provider.models.count))"
                            : entry.provider.name) {
                        ForEach(entry.models) { model in
                            let reference = AppModel.ModelRef(provider: entry.provider.id, modelId: model.id)
                            Button {
                                choose(reference)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(model.name)
                                        if model.name != model.id {
                                            Text(model.id).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if reference == selection { Image(systemName: "checkmark") }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .overlay {
                if !search.isEmpty, shown.isEmpty, !app.usableProviders.isEmpty { ContentUnavailableView.search(text: search) }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search models")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @Bindable var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var linkError: String?
    @State private var endpoint = ""
    @State private var serverName = ""
    @State private var watchAlerts = false
    @State private var watchVoiceStatus: String?
    @State private var choosingDefault = false
    @State private var search = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Default model for new sessions") {
                    Button {
                        choosingDefault = true
                    } label: {
                        HStack {
                            Text(app.defaultModel.map(app.displayName(of:)) ?? "Choose…")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                    // How much new sessions' models think: each takes the nearest level it has.
                    if let model = app.defaultModel, app.thinkingLevels(of: model).count > 1 {
                        Picker(selection: $app.defaultThinkingLevel) {
                            ForEach(app.thinkingLevels(of: model), id: \.self) { level in
                                Text(AppModel.thinkingTitle(level)).tag(level)
                            }
                        } label: {
                            Label("Thinking", systemImage: "brain")
                        }
                    }
                }

                Section {
                    ForEach(signedIn) { provider in providerLink(provider) }
                    NavigationLink("Add account") {
                        List(available) { provider in providerLink(provider) }
                            .searchable(text: $search)
                            .navigationTitle("Providers")
                    }
                } header: {
                    Text("Accounts")
                } footer: {
                    Text("Sign in with pi's own login flows or an API key. Credentials are kept in the Keychain and sync to your other devices through iCloud Keychain.")
                }

                Section {
                    NavigationLink("Extensions and skills") { ExtensionsView(app: app) }
                    NavigationLink("MCP servers") { MCPServersView(app: app) }
                    NavigationLink("Vault") { VaultView(vault: app.vault) }
                } footer: {
                    Text("What every session loads, what sessions added for themselves, the skills, the MCP servers whose tools every session has, and your vault: card and document numbers behind Face ID.")
                }

                Section {
                    Button("Use This Device's Settings Everywhere", systemImage: "icloud.and.arrow.up") {
                        SyncedSettings.shared.sendThisDevice()
                    }
                } header: {
                    Text("iCloud")
                } footer: {
                    Text("Sign-ins, the network server, the default model, extensions and their secrets, MCP servers and the vault sync to your devices signed in to the same Apple Account, through iCloud Keychain (end-to-end encrypted). Changes from another device apply when pi starts; the newest change wins, and lists merge item by item. Sessions stay on each device.")
                }

                BrowsersSection(app: app)

                CrabboxSection(app: app)

                GitHubSection(app: app)

                onDeviceSection

                Section {
                    TextField("http://192.168.1.10:11434/v1", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Name (optional)", text: $serverName)
                        .autocorrectionDisabled()
                    Button("Save") {
                        app.networkEndpoint = endpoint
                        app.networkName = serverName.trimmingCharacters(in: .whitespaces)
                        Task { await app.updateCustomProviders() }
                    }
                    .disabled(endpoint == app.networkEndpoint && serverName.trimmingCharacters(in: .whitespaces) == app.networkName)
                } header: {
                    Text("Network server")
                } footer: {
                    Text("An OpenAI-compatible server, such as Ollama on your Mac. Its models are discovered automatically. Sessions show its name, or its address without one.")
                }

                Section {
                    Button("Enable voice transcription") {
                        Task {
                            watchVoiceStatus = await app.watchCompanion.enableVoice()
                                ? "Voice transcription is enabled."
                                : "Allow Speech Recognition for Pi in iPhone Settings → Privacy & Security."
                        }
                    }
                    if let watchVoiceStatus { Text(watchVoiceStatus).font(.caption).foregroundStyle(.secondary) }
                    Toggle("Task completion alerts", isOn: $watchAlerts)
                        .onChange(of: watchAlerts) {
                            if watchAlerts {
                                Task {
                                    await app.watchCompanion.enableAlerts()
                                    watchAlerts = app.watchCompanion.alertsEnabled
                                }
                            } else { app.watchCompanion.disableAlerts() }
                    }
                } header: {
                    Text("Apple Watch")
                } footer: {
                    Text("Record prompts on your Watch, then review and send the transcript. Your iPhone transcribes them on device when supported; otherwise Apple may process the audio. Alerts follow your iPhone's notification mirroring settings. Open Pi on iPhone if a task needs permission or more time in the background.")
                }

                Section("About") {
                    HStack(spacing: 14) {
                        Logo(size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("pi").font(.title3.bold())
                            Text("The pi coding agent, running on this phone").font(.footnote).foregroundStyle(.secondary)
                            Text("Reindeer AI").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    LabeledContent("Engine") { Text(app.environment).font(.footnote) }
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
            .onAppear {
                watchAlerts = app.watchCompanion.alertsEnabled
                endpoint = app.networkEndpoint
                serverName = app.networkName
            }
            .sheet(isPresented: $choosingDefault) {
                ModelPicker(app: app, selection: app.defaultModel) { app.defaultModel = $0 }
            }
        }
        .sheet(isPresented: Binding(get: { app.authFlow != nil }, set: { if !$0 { app.cancelLogin() } })) {
            AuthSheet(app: app)
        }
    }

    private var signedIn: [AppModel.Provider] {
        app.providers.filter { $0.configured && !$0.custom }
    }

    private var available: [AppModel.Provider] {
        app.providers.filter { !$0.configured && !$0.custom }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { $0.name < $1.name }
    }

    private func providerLink(_ provider: AppModel.Provider) -> some View {
        NavigationLink {
            ProviderView(app: app, providerId: provider.id)
        } label: {
            HStack {
                Text(provider.name)
                Spacer()
                if provider.configured { Text("Signed in").font(.caption).foregroundStyle(.green) }
            }
        }
    }

    private var onDeviceSection: some View {
        Section {
            TextField("Hugging Face link to a .gguf file", text: $link, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Download") {
                do {
                    try app.models.startDownload(from: link)
                    linkError = nil
                    link = ""
                } catch {
                    linkError = error.localizedDescription
                }
            }
            .disabled(link.isEmpty || app.models.download != nil)
            if let linkError { Text(linkError).font(.footnote).foregroundStyle(.red) }
            if let download = app.models.download {
                VStack(alignment: .leading) {
                    ProgressView(value: download.fraction) {
                        Text(download.fileName).font(.footnote)
                    } currentValueLabel: {
                        Text(String(format: "%.2f of %.2f GB", Double(download.received) / 1e9, Double(download.expected) / 1e9))
                    }
                    if let error = download.error { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            ForEach(app.models.models, id: \.self) { file in
                Text(file).font(.footnote)
            }
            .onDelete { offsets in
                for file in offsets.map({ app.models.models[$0] }) {
                    if app.preloadedModel == file { app.preloadedModel = nil }
                    app.models.delete(file)
                }
            }
            if !app.models.models.isEmpty {
                Picker("Keep loaded", selection: $app.preloadedModel) {
                    Text("None").tag(String?.none)
                    ForEach(app.models.models, id: \.self) { file in Text(file).tag(String?.some(file)) }
                }
                Picker("Context window", selection: $app.localContextSize) {
                    ForEach(AppModel.localContextSizes, id: \.self) { size in Text("\(size / 1024)K tokens").tag(size) }
                }
            }
            if let status = app.localModelStatus { Text(status).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("On-device models")
        } footer: {
            Text("Downloads a GGUF model to this phone and runs it with llama.cpp. Choose it as a session's model. A model kept loaded starts with the app, so sessions using it reply without waiting for it to load; it uses memory the whole time. A larger context window fits longer conversations and uses more memory; the status shows the headroom left.")
        }
    }
}

/// A Crabbox broker (openclaw/crabbox) leases real Linux machines the agent runs commands on. Sign in with GitHub (the
/// broker's own login, completed on this device) or a token from elsewhere.
private struct CrabboxSection: View {
    @Bindable var app: AppModel
    @State private var broker = ""
    @State private var signedIn = false
    @State private var identity: String?
    @State private var working = false
    @State private var error: String?
    @State private var loginURL: URL?
    @State private var enteringToken = false
    @State private var token = ""
    @FocusState private var editingBroker: Bool
    @State private var provider = ""

    /// The providers `crabbox login --provider` offers that lease a box reachable over SSH (Daytona runs commands
    /// itself instead).
    private static let providers = ["aws", "azure", "gcp", "hetzner"]
    private static let providerNames = ["aws": "AWS", "azure": "Azure", "gcp": "Google Cloud", "hetzner": "Hetzner"]

    private var brokerChanged: Bool { broker.trimmingCharacters(in: .whitespaces) != (app.crabbox.broker ?? "") }

    var body: some View {
        Section {
            TextField("https://broker.example.com", text: $broker)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.done)
                .focused($editingBroker)
                .onSubmit { if brokerChanged { saveBroker() } }
            if brokerChanged {
                Button("Save broker", action: saveBroker)
            } else if app.crabbox.broker != nil {
                if signedIn {
                    LabeledContent("Signed in", value: identity ?? "")
                    Picker("Machines from", selection: $provider) {
                        Text("Broker's default").tag("")
                        ForEach(Self.providers, id: \.self) { Text(Self.providerNames[$0] ?? $0).tag($0) }
                        if !provider.isEmpty, !Self.providers.contains(provider) { Text(provider).tag(provider) }
                    }
                    .onChange(of: provider) { _, chosen in app.crabbox.setProvider(chosen.isEmpty ? nil : chosen) }
                    Button("Sign out", role: .destructive) {
                        app.crabbox.signOut()
                        refresh()
                        Task { await app.crabboxChanged() }
                    }
                } else {
                    Button("Sign in with GitHub", action: signInWithGitHub).disabled(working)
                    Button("Use a token") { enteringToken = true }.disabled(working)
                }
            }
            if working { ProgressView() }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("Crabbox")
        } footer: {
            Text("A Crabbox broker leases real Linux machines for what this phone can't do: Node, compilers, Docker, builds. The agent runs commands there on a copy of the session's workspace. The token and SSH keys stay in this device's Keychain. A broker behind Cloudflare WARP needs WARP on this phone. A new provider applies to the next machine a session leases.")
        }
        .onAppear {
            broker = app.crabbox.broker ?? ""
            refresh()
        }
        .sheet(item: $loginURL) { url in SafariView(url: url).ignoresSafeArea() }
        .alert("Crabbox token", isPresented: $enteringToken) {
            SecureField("Token", text: $token)
                .textContentType(.oneTimeCode)
            Button("Sign in") { signIn(token: token) }
            Button("Cancel", role: .cancel) { token = "" }
        } message: {
            Text("A token from crabbox login on another machine, or an operator token.")
        }
    }

    private func saveBroker() {
        editingBroker = false
        app.crabbox.setBroker(broker)
        refresh()
        Task { await app.crabboxChanged() }
    }

    private func refresh() {
        signedIn = app.crabbox.signedIn
        provider = app.crabbox.provider ?? ""
        let who = app.crabbox.identity
        identity = [who?["owner"] as? String, (who?["org"] as? String).map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    }

    private func signInWithGitHub() {
        run { try await app.crabbox.signInWithGitHub { loginURL = $0 } }
    }

    private func signIn(token: String) {
        run { try await app.crabbox.signIn(token: token) }
        self.token = ""
    }

    private func run(_ signIn: @escaping () async throws -> [String: Any]) {
        working = true
        error = nil
        Task {
            do {
                _ = try await signIn()
                await app.crabboxChanged()
            } catch {
                self.error = error.localizedDescription
            }
            loginURL = nil
            working = false
            refresh()
        }
    }
}

private struct BrowsersSection: View {
    @Bindable var app: AppModel
    @State private var naming = false
    @State private var name = ""

    private var profiles: BrowserProfiles { app.browser.profiles }

    var body: some View {
        Section {
            Picker("New sessions use", selection: Binding(get: { profiles.defaultKey }, set: { profiles.defaultKey = $0 })) {
                ForEach(profiles.profiles) { profile in Text(profile.name).tag(profile.key) }
                Text("Private").tag(BrowserProfiles.privateKey)
            }
            ForEach(profiles.profiles) { profile in
                NavigationLink(profile.name) { BrowserProfileView(app: app, key: profile.key) }
            }
            Button("Add profile") {
                name = ""
                naming = true
            }
        } header: {
            Text("Browsers")
        } footer: {
            Text("Each profile keeps its own logins, shared by every session that uses it. Private keeps nothing. A session's menu changes its browser.")
        }
        .alert("New profile", isPresented: $naming) {
            TextField("Name, such as Work", text: $name)
            Button("Add") { if !name.trimmingCharacters(in: .whitespaces).isEmpty { profiles.create(name: name) } }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct BrowserProfileView: View {
    @Bindable var app: AppModel
    let key: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var browsing: BrowserSession?
    @State private var confirmingClear = false
    @State private var confirmingDelete = false
    @State private var error: String?

    private var profiles: BrowserProfiles { app.browser.profiles }
    private var sessionsUsing: Int { app.sessions.filter { $0.browser == key }.count }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $name).onSubmit { profiles.rename(key, to: name) }
            }
            Section {
                Button("Open browser", systemImage: "safari") { browsing = app.browser.standaloneBrowser(for: key) }
                if profiles.defaultKey != key {
                    Button("Use for new sessions", systemImage: "checkmark.circle") { profiles.defaultKey = key }
                }
            } footer: {
                Text("Sign in to sites here once; every session on this profile is then signed in. \(sessionsUsing) session\(sessionsUsing == 1 ? "" : "s") use it.")
            }
            Section {
                Button("Clear site data", role: .destructive) { confirmingClear = true }
                Button("Delete profile", role: .destructive) { confirmingDelete = true }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .navigationTitle(profiles.name(of: key) ?? "")
        .onAppear { name = profiles.name(of: key) ?? "" }
        .onDisappear { if !name.isEmpty, name != profiles.name(of: key), profiles.name(of: key) != nil { profiles.rename(key, to: name) } }
        .fullScreenCover(item: $browsing) { browser in BrowserScreen(browser: browser, profileName: name) }
        .confirmationDialog("Sign out of every site on this profile?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear site data", role: .destructive) { Task { await profiles.clearData(key) } }
        }
        .confirmationDialog("Delete this profile and its logins?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete profile", role: .destructive) {
                Task {
                    do {
                        try await app.deleteBrowserProfile(key)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
        } message: {
            Text(sessionsUsing > 0 ? "\(sessionsUsing) session\(sessionsUsing == 1 ? "" : "s") will have no browser until you choose another profile for them." : "")
        }
    }
}

private struct ProviderView: View {
    @Bindable var app: AppModel
    let providerId: String

    private var provider: AppModel.Provider? { app.providers.first { $0.id == providerId } }

    var body: some View {
        Form {
            if let provider {
                Section {
                    LabeledContent("Status", value: provider.configured ? "Signed in" : "Not signed in")
                    if provider.configured { LabeledContent("Models", value: "\(provider.models.count)") }
                }
                Section {
                    if let oauthName = provider.oauthName {
                        // Anthropic's terms bar Claude Pro/Max subscription tokens in third-party apps.
                        if provider.id == "anthropic" && provider.isSubscription {
                            Text("Claude Pro/Max sign-in isn't permitted in third-party apps. Use an API key.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Button(provider.oauthLabel ?? "Sign in with \(oauthName)") { app.login(provider.id, type: "oauth") }
                        }
                    }
                    if provider.canEnterAPIKey, let name = provider.apiKeyName {
                        Button("Enter \(name)") { app.login(provider.id, type: "api_key") }
                    }
                    if provider.configured {
                        Button("Sign out", role: .destructive) { Task { await app.logout(provider.id) } }
                    }
                }
            }
        }
        .navigationTitle(provider?.name ?? "")
    }
}

// MARK: - Sign-in

private struct AuthSheet: View {
    @Bindable var app: AppModel
    @State private var value = ""
    @State private var browserURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                if let flow = app.authFlow {
                    if let url = flow.url {
                        Section {
                            if let instructions = flow.instructions { Text(instructions).font(.footnote) }
                            Button("Open sign-in page") { browserURL = url }
                        }
                    }
                    if let deviceCode = flow.deviceCode {
                        Section("Enter this code") {
                            Text(deviceCode.code).font(.largeTitle.monospaced().bold()).textSelection(.enabled)
                            Button("Copy code") { UIPasteboard.general.string = deviceCode.code }
                            if let uri = deviceCode.uri { Button("Open \(uri.host() ?? uri.absoluteString)") { browserURL = uri } }
                        }
                    }
                    if let prompt = flow.prompt { promptSection(prompt) }
                    if !flow.progress.isEmpty {
                        Section { ForEach(flow.progress, id: \.self) { Text($0).font(.footnote) } }
                    }
                    if flow.done {
                        Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    if let error = flow.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                    if flow.url == nil, flow.deviceCode == nil, flow.prompt == nil, !flow.done, flow.error == nil {
                        ProgressView()
                    }
                }
            }
            .navigationTitle(app.providers.first { $0.id == app.authFlow?.providerId }?.name ?? "Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button(app.authFlow?.done == true || app.authFlow?.error != nil ? "Done" : "Cancel") { app.cancelLogin() }
            }
            .sheet(item: $browserURL) { url in SafariView(url: url).ignoresSafeArea() }
        }
    }

    @ViewBuilder
    private func promptSection(_ prompt: AppModel.AuthFlow.Prompt) -> some View {
        Section {
            Text(prompt.message)
            switch prompt.kind {
            case "select":
                ForEach(prompt.options, id: \.id) { option in
                    Button(option.label) { app.answerAuthPrompt(option.id) }
                }
            case "secret":
                SecureField(prompt.placeholder ?? "", text: $value)
                    .textContentType(.oneTimeCode)
                submit
            default:
                TextField(prompt.placeholder ?? "", text: $value, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                submit
            }
        }
        .id(prompt.id)
    }

    private var submit: some View {
        Button("Continue") {
            app.answerAuthPrompt(value)
            value = ""
        }
        .disabled(value.isEmpty)
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// The user's GitHub account: a device login (when the build has a GitHub app) or a pasted token, kept in the Keychain.
private struct GitHubSection: View {
    @Bindable var app: AppModel
    @Environment(\.openURL) private var openURL
    @State private var identity: [String: Any]?
    @State private var working = false
    @State private var error: String?
    @State private var deviceCode: GitHubService.DeviceCode?
    @State private var enteringToken = false
    @State private var token = ""
    @State private var login: Task<Void, Never>?

    var body: some View {
        Section {
            if let identity {
                LabeledContent("Signed in", value: [identity["login"] as? String, (identity["name"] as? String).map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
                if let scopes = identity["scopes"] as? [String], !scopes.isEmpty {
                    LabeledContent("Access", value: scopes.joined(separator: ", ")).font(.footnote)
                }
                Button("Sign out", role: .destructive) {
                    app.github.signOut()
                    refresh()
                    Task { await app.githubChanged() }
                }
            } else if let deviceCode {
                Text(deviceCode.userCode).font(.largeTitle.monospaced().bold()).textSelection(.enabled)
                // In Safari, where the user is likely signed in to GitHub already; the login keeps waiting meanwhile.
                Button("Copy code and open GitHub") {
                    UIPasteboard.general.string = deviceCode.userCode
                    openURL(deviceCode.verificationURL)
                }
                Button("Cancel", role: .cancel) { login?.cancel() }
            } else {
                if app.github.clientID != nil { Button("Sign in with GitHub", action: signInWithDevice).disabled(working) }
                Button("Use a token") { enteringToken = true }.disabled(working)
            }
            if working, deviceCode == nil { ProgressView() }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("GitHub")
        } footer: {
            Text("The agent uses your GitHub account through the GitHub API here, and with gh and git on Crabbox machines, where the app puts the token for your commands. The token stays in this device's Keychain; the agent never sees it.")
        }
        .onAppear(perform: refresh)
        .alert("GitHub token", isPresented: $enteringToken) {
            SecureField("Token", text: $token)
                .textContentType(.oneTimeCode)
            Button("Sign in") { signIn(token: token) }
            Button("Cancel", role: .cancel) { token = "" }
        } message: {
            Text("A personal access token (classic with repo, read:org and workflow, or fine-grained), or the output of gh auth token.")
        }
    }

    private func refresh() {
        identity = app.github.identity
    }

    private func signIn(token: String) {
        run { try await app.github.signIn(token: token) }
        self.token = ""
    }

    private func signInWithDevice() {
        run { try await app.github.signInWithDevice { code in deviceCode = code } }
    }

    private func run(_ signIn: @escaping () async throws -> [String: Any]) {
        working = true
        error = nil
        login = Task {
            do {
                _ = try await signIn()
                await app.githubChanged()
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            deviceCode = nil
            working = false
            refresh()
        }
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Hosts the engine's web view at 1×1 point, nearly transparent, so WebKit treats the page as visible.
private struct EngineHostView: UIViewRepresentable {
    let engine: PiEngine

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        container.isUserInteractionEnabled = false
        container.alpha = 0.01
        engine.webView.frame = container.bounds
        container.addSubview(engine.webView)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        CGSize(width: 1, height: 1)
    }
}

/// A message's text for its Select Text sheet.
struct SelectableText: Identifiable {
    let id = UUID()
    let text: String
}

/// A message's whole text, to select any part of it and copy that (SwiftUI's selectable Text copies only all of it).
private struct SelectTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableTextView(text: text)
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Copy All", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = text
                            dismiss()
                        }
                    }
                }
        }
    }
}

/// Read-only text with the system's selection handles and its Copy, Look Up and Share menu.
private struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
