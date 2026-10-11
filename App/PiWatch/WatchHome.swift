import SwiftUI
import WatchKit
import PiWatchLink

struct WatchHome: View {
    @Bindable var model: WatchModel
    @State private var path: [Int] = []
    @State private var composing = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Text(model.reachable ? "Phone connected" : "Phone disconnected")
                        .font(.caption).foregroundStyle(model.reachable ? .green : .secondary)
                    Button("New session", systemImage: "mic.fill") { composing = true }
                        .disabled(model.snapshot == nil || model.voiceDraft != nil)
                    Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                    if let date = model.snapshot?.updatedAt {
                        Text("Synced \(date, style: .relative) ago").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if model.snapshot == nil {
                    Text("Open Pi on your paired iPhone, configure a default model, then refresh.")
                }
                if model.voiceDraft != nil {
                    Section("Recorded prompt") {
                        Button("Review recording", systemImage: "waveform") { composing = true }
                        Text(model.voiceDraft?.reply?.error ?? (model.voiceDraft?.reply?.text.isEmpty == false ? "Ready to review and send" : "Waiting for transcription on iPhone"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !model.pending.isEmpty {
                    Section("Waiting to send") {
                        ForEach(model.pending) { request in
                            NavigationLink { PendingPrompt(model: model, request: request) } label: {
                                if case .prompt(_, _, let text) = request.command {
                                    VStack(alignment: .leading) {
                                        Text(text).lineLimit(2)
                                        Text(model.failures[request.id] ?? "Not acknowledged by phone")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }.swipeActions(edge: .trailing) {
                                Button("Remove", systemImage: "trash", role: .destructive) { model.cancel(request) }
                            }
                        }
                    }
                }
                if !model.visibleRuns.isEmpty {
                    Section("Watch tasks") {
                        ForEach(model.visibleRuns) { run in
                            NavigationLink { WatchTask(model: model, runID: run.id) } label: {
                                VStack(alignment: .leading) {
                                    if case .prompt(_, _, let text) = run.request.command { Text(text).lineLimit(2) }
                                    Text(run.state.label).font(.caption2).foregroundStyle(.secondary)
                                }
                            }.swipeActions(edge: .trailing) {
                                Button("Remove", systemImage: "trash", role: .destructive) { model.hide(run) }
                            }
                        }
                    }
                }
                Section("Recent sessions") {
                    ForEach(model.visibleSessions) { session in
                        NavigationLink(value: session.id) {
                            VStack(alignment: .leading) {
                                Text(session.title).lineLimit(2)
                                Text(session.needsPhone ? "Needs iPhone" : session.running ? "Working" : session.preview)
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }.swipeActions(edge: .trailing) {
                            Button("Remove", systemImage: "trash", role: .destructive) { model.hide(session) }
                        }
                    }
                    Text("Swipe left to remove from this Watch. Sessions and work stay on iPhone.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Pi")
            .navigationDestination(for: Int.self) { id in WatchConversationView(model: model, id: id) }
            .sheet(isPresented: $composing) { WatchVoiceComposer(model: model, sessionID: nil) }
            .onChange(of: model.requestedSession) {
                if let id = model.requestedSession { path = [id]; model.requestedSession = nil }
            }
            .onChange(of: model.snapshot?.hostID) {
                path = []
                composing = false
            }
            .onAppear {
                if let id = model.requestedSession { path = [id]; model.requestedSession = nil }
            }
            .alert("Pi", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }
}

private struct WatchConversationView: View {
    @Bindable var model: WatchModel
    let id: Int
    @State private var composing = false
    private var session: WatchSession? { model.snapshot?.sessions.first { $0.id == id } }
    var body: some View {
        ScrollViewReader { proxy in
            List {
                if session?.needsPhone == true { Text("Pi needs a response on iPhone.").foregroundStyle(.orange) }
                if session?.running == true { Label("Working on iPhone", systemImage: "hourglass") }
                if let error = session?.error { Text(error).foregroundStyle(.orange) }
                if let messages = model.conversations[id]?.messages, !messages.isEmpty {
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.role == .user ? "You" : "Pi").font(.caption2).foregroundStyle(.secondary)
                            Text(message.text)
                            if message.truncated { Text("Continued on iPhone").font(.caption2).foregroundStyle(.secondary) }
                            if message.role == .assistant && !message.text.isEmpty {
                                Button("Listen", systemImage: "speaker.wave.2") { model.speak(message.text) }
                            }
                        }
                    }
                } else { Text("Refresh to load this conversation.") }
                Button("Reply", systemImage: "mic.fill") { composing = true }
                    .disabled(model.voiceDraft != nil)
                Button("Refresh", systemImage: "arrow.clockwise") { model.open(id) }
                Button("Stop speaking") { model.stopSpeaking() }
                Text("Recent messages only. Pi may need to be opened on iPhone to continue a long task.").font(.caption2).foregroundStyle(.secondary)
            }
            .onChange(of: model.conversations[id]?.messages.last?.id) {
                if let last = model.conversations[id]?.messages.last?.id { proxy.scrollTo(last, anchor: .top) }
            }
            .onAppear {
                if let last = model.conversations[id]?.messages.last?.id { proxy.scrollTo(last, anchor: .top) }
            }
        }
        .navigationTitle(session?.title ?? "Session")
        .task { model.open(id) }
        .sheet(isPresented: $composing) { WatchVoiceComposer(model: model, sessionID: id) }
        .onDisappear { model.stopSpeaking() }
    }
}

private struct WatchTask: View {
    @Bindable var model: WatchModel
    let runID: UUID
    var body: some View {
        List {
            if let run = model.snapshot?.runs.first(where: { $0.id == runID }) {
                Text(run.state.label).font(.headline)
                if let error = run.error { Text(error).foregroundStyle(.orange) }
                if !run.answer.isEmpty {
                    Text(run.answer)
                    Button("Listen", systemImage: "speaker.wave.2") { model.speak(run.answer) }
                    Button("Stop speaking") { model.stopSpeaking() }
                }
                if let id = run.sessionID { NavigationLink(value: id) { Text("Open session") } }
                if !run.state.terminal { Text("Long tasks may pause until Pi is opened on iPhone.").font(.caption) }
            } else { Text("Refresh to see this task.") }
            Button("Refresh") { model.refresh() }
        }.navigationTitle("Task").onDisappear { model.stopSpeaking() }
    }
}

private struct PendingPrompt: View {
    @Bindable var model: WatchModel
    let request: WatchRequest
    var body: some View {
        List {
            if case .prompt(_, _, let text) = request.command { Text(text) }
            if let error = model.failures[request.id] { Text(error).foregroundStyle(.orange) }
            Text("Your phone has not acknowledged this message.").font(.caption)
            Button("Retry") { model.retry(request) }
            Button("Remove from Watch", role: .destructive) { model.cancel(request) }
            Text("Removing stops queued delivery when possible. It does not cancel a task already received by iPhone.").font(.caption2)
        }.navigationTitle("Waiting")
    }
}

private extension WatchRun.State {
    var label: String {
        switch self {
        case .received: "Received by phone"
        case .queued: "Queued on phone"
        case .running: "Working on phone"
        case .answered: "Finished"
        case .failed: "Needs attention"
        }
    }
}
