import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AutolevelerCore

@main
struct AutolevelerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Autoleveler", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 780, minHeight: 500)
                .tint(Color(red: 0.18, green: 0.67, blue: 0.62))
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…", action: model.openFiles)
                    .keyboardShortcut("o", modifiers: .command)

                Button("Start Processing", action: model.startProcessing)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canStart)

                Button("Cancel Processing", action: model.cancelProcessing)
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.isProcessing)
            }
            CommandGroup(after: .help) {
                Button("Third-Party Notices") {
                    AppModel.openThirdPartyNotices()
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.enqueue(urls)
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        AppModel.shared.enqueue(filenames.map(URL.init(fileURLWithPath:)))
        application.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.isProcessing else { return .terminateNow }
        AppModel.shared.cancelForTermination()
        return .terminateLater
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    static func openThirdPartyNotices() {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("ThirdParty/THIRD_PARTY_NOTICES.md"),
              FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    enum ItemState: Equatable {
        case waiting
        case processing
        case completed
        case failed
        case cancelled
    }

    struct QueueItem: Identifiable {
        let id = UUID()
        let url: URL
        var state: ItemState = .waiting
        var progress = 0.0
        var message = "Waiting"
        var output: URL?
        var speechDetected: Bool?
        var error: String?

        var displayName: String { url.lastPathComponent }
    }

    @Published private(set) var items: [QueueItem] = []
    @Published var codec: AudioCodec = .aac
    @Published var bitrate = 192
    @Published var outputMode: OutputMode = .automatic
    @Published var destinationDirectory: URL?
    @Published private(set) var isProcessing = false
    @Published private(set) var statusMessage = "Drop media here or open files to begin."
    @Published var isDropTargeted = false

    private var processingTask: Task<Void, Never>?
    private var activeCancellation: CancellationToken?
    private var cancellationRequested = false
    private var pendingTermination = false

    var canStart: Bool {
        !isProcessing && items.contains { $0.state == .waiting }
    }

    var completedCount: Int { items.filter { $0.state == .completed }.count }
    var finishedCount: Int {
        items.filter { $0.state == .completed || $0.state == .failed || $0.state == .cancelled }.count
    }

    func enqueue(_ urls: [URL]) {
        var existing = Set(items.map { $0.url.standardizedFileURL })
        let additions = urls.compactMap { url -> QueueItem? in
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { return nil }
            guard existing.insert(url.standardizedFileURL).inserted else { return nil }
            return QueueItem(url: url)
        }

        guard !additions.isEmpty else { return }
        items.append(contentsOf: additions)
        statusMessage = "\(items.count) file\(items.count == 1 ? "" : "s") queued."
    }

    func enqueueDropProviders(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                let url: URL?
                if let item = item as? URL {
                    url = item
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }

                guard let url else { return }
                Task { @MainActor [weak self] in
                    self?.enqueue([url])
                }
            }
        }
        return true
    }

    func openFiles() {
        let panel = NSOpenPanel()
        panel.title = "Choose Media"
        panel.prompt = "Add to Queue"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsOtherFileTypes = true
        panel.allowedContentTypes = []

        if panel.runModal() == .OK {
            enqueue(panel.urls)
        }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "Choose Output Folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK {
            destinationDirectory = panel.url
        }
    }

    func clearFinished() {
        guard !isProcessing else { return }
        items.removeAll { $0.state == .completed || $0.state == .failed || $0.state == .cancelled }
        statusMessage = items.isEmpty ? "Drop media here or open files to begin." : "Finished files cleared."
    }

    func retryItem(id: UUID) {
        guard !isProcessing, let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].state == .failed || items[index].state == .cancelled else { return }
        items[index].state = .waiting
        items[index].progress = 0
        items[index].message = "Waiting"
        items[index].error = nil
        items[index].output = nil
        items[index].speechDetected = nil
        statusMessage = "Ready to retry \(items[index].displayName)."
    }

    func removeItem(id: UUID) {
        guard !isProcessing else { return }
        items.removeAll { $0.id == id }
        statusMessage = items.isEmpty ? "Drop media here or open files to begin." : "\(items.count) file\(items.count == 1 ? "" : "s") queued."
    }

    func startProcessing() {
        guard canStart else { return }
        cancellationRequested = false
        isProcessing = true
        statusMessage = "Preparing queue…"
        processingTask = Task { [weak self] in
            await self?.runQueue()
        }
    }

    func cancelProcessing() {
        guard isProcessing else { return }
        cancellationRequested = true
        activeCancellation?.cancel()
        processingTask?.cancel()
        statusMessage = "Cancelling…"
    }

    func cancelForTermination() {
        pendingTermination = true
        cancelProcessing()
    }

    private func runQueue() async {
        let waitingIDs = items.filter { $0.state == .waiting }.map(\.id)

        for id in waitingIDs {
            guard !Task.isCancelled, let index = items.firstIndex(where: { $0.id == id }) else { break }

            items[index].state = .processing
            items[index].progress = 0
            items[index].message = "Preparing…"
            items[index].error = nil
            statusMessage = "Processing \(items[index].displayName)"

            let input = items[index].url
            let options = ProcessingOptions(
                codec: codec,
                bitrate: bitrate,
                outputMode: outputMode,
                outputDirectory: destinationDirectory
            )
            let token = CancellationToken()
            activeCancellation = token
            let progressSink: @Sendable (ProcessingProgress) -> Void = { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.updateProgress(id: id, progress: progress)
                }
            }

            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let processor = try MediaProcessor()
                    return try processor.process(input: input, options: options, cancellation: token, progress: progressSink)
                }.value

                guard let completedIndex = items.firstIndex(where: { $0.id == id }) else { continue }
                items[completedIndex].state = .completed
                items[completedIndex].progress = 1
                items[completedIndex].message = result.speechDetected ? "Complete" : "Complete · speech not detected"
                items[completedIndex].output = result.output
                items[completedIndex].speechDetected = result.speechDetected
            } catch {
                guard let failedIndex = items.firstIndex(where: { $0.id == id }) else { continue }
                if cancellationRequested || Task.isCancelled {
                    items[failedIndex].state = .cancelled
                    items[failedIndex].message = "Cancelled"
                } else {
                    items[failedIndex].state = .failed
                    items[failedIndex].message = "Failed"
                    items[failedIndex].error = error.localizedDescription
                }
            }

            activeCancellation = nil
            if cancellationRequested || Task.isCancelled { break }
        }

        finishQueue()
    }

    private func updateProgress(id: UUID, progress: ProcessingProgress) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state == .processing else { return }
        items[index].progress = min(max(progress.fraction, 0), 1)
        items[index].message = progress.message
    }

    private func finishQueue() {
        activeCancellation = nil
        processingTask = nil
        isProcessing = false
        if cancellationRequested {
            statusMessage = "Processing cancelled."
        } else {
            statusMessage = completedCount > 0 ? "Finished \(completedCount) file\(completedCount == 1 ? "" : "s")." : "Queue finished."
        }

        if pendingTermination {
            pendingTermination = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                queuePane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                optionsPane
                    .frame(width: 255)
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.isDropTargeted, perform: model.enqueueDropProviders)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Autoleveler")
                    .font(.title2.weight(.semibold))
                Text("Even dialogue. Quiet pauses.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open…", action: model.openFiles)
                .keyboardShortcut("o", modifiers: .command)
        }
        .padding(20)
    }

    private var queuePane: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Queue")
                    .font(.headline)
                Spacer()
                if model.finishedCount > 0 {
                    Button("Clear Finished", action: model.clearFinished)
                        .buttonStyle(.link)
                        .disabled(model.isProcessing)
                }
            }

            if model.items.isEmpty {
                dropZone
            } else {
                List {
                    ForEach(model.items) { item in
                        QueueRow(item: item, retry: {
                            model.retryItem(id: item.id)
                        }, remove: {
                            model.removeItem(id: item.id)
                        }) {
                            if let output = item.output {
                                NSWorkspace.shared.activateFileViewerSelecting([output])
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text("Drop audio or video files here")
                .font(.headline)
            Text("or use Open to add multiple files")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 235)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(model.isDropTargeted ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.035))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(model.isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [6]))
                }
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.isDropTargeted)
    }

    private var optionsPane: some View {
        Form {
            Section("Output") {
                Picker("Mode", selection: $model.outputMode) {
                    ForEach(OutputMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                Picker("Codec", selection: $model.codec) {
                    ForEach(AudioCodec.allCases) { codec in
                        Text(codec.label).tag(codec)
                    }
                }

                Picker("Bitrate", selection: $model.bitrate) {
                    Text("128 kbps").tag(128)
                    Text("192 kbps").tag(192)
                    Text("256 kbps").tag(256)
                    Text("320 kbps").tag(320)
                }
                .disabled(model.isProcessing || model.codec == .pcm)
            }
            .disabled(model.isProcessing)

            Section("Destination") {
                Button {
                    model.chooseDestination()
                } label: {
                    Label(model.destinationDirectory?.lastPathComponent ?? "Same folder as source", systemImage: "folder")
                        .lineLimit(1)
                }
                .buttonStyle(.link)
                .disabled(model.isProcessing)

                if model.destinationDirectory != nil {
                    Button("Use source folder", action: { model.destinationDirectory = nil })
                        .buttonStyle(.link)
                        .foregroundStyle(.secondary)
                        .disabled(model.isProcessing)
                }
            }

            Section {
                Button(model.isProcessing ? "Cancel Processing" : "Start Processing") {
                    model.isProcessing ? model.cancelProcessing() : model.startProcessing()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isProcessing ? false : !model.canStart)
                .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 10)
        .padding(.horizontal, 12)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.isProcessing {
                ProcessingIndicator(reduceMotion: reduceMotion)
            } else {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            Text(model.statusMessage)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text("⌘↩ Start  ·  ⌘. Cancel")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

struct QueueRow: View {
    let item: AppModel.QueueItem
    let retry: () -> Void
    let remove: () -> Void
    let revealOutput: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .lineLimit(1)
                if item.state == .processing {
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                }
                if let error = item.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .help(error)
                } else {
                    Text(item.message)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if item.state == .completed {
                if item.speechDetected == false {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("No speech was detected; the output may be unchanged.")
                }
                Button("Show", action: revealOutput)
                    .buttonStyle(.link)
            }
            if item.state == .failed || item.state == .cancelled {
                Button("Retry", action: retry)
                    .buttonStyle(.link)
            }
            if item.state != .processing {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from queue")
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch item.state {
        case .waiting: return "circle"
        case .processing: return "circle.lefthalf.filled"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "slash.circle"
        }
    }

    private var iconColor: Color {
        switch item.state {
        case .waiting: return .secondary
        case .processing: return .accentColor
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
}

struct ProcessingIndicator: View {
    let reduceMotion: Bool
    @State private var isAnimating = false
    private let heights: [CGFloat] = [8, 13, 10, 16, 7]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: heights[index])
                    .scaleEffect(y: reduceMotion ? 1 : (isAnimating ? 1 : 0.45), anchor: .bottom)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.45).repeatForever(autoreverses: true).delay(Double(index) * 0.07),
                        value: isAnimating
                    )
            }
        }
        .frame(width: 27, height: 18)
        .onAppear {
            if !reduceMotion { isAnimating = true }
        }
        .onChange(of: reduceMotion) { _, value in
            isAnimating = !value
        }
        .accessibilityLabel("Processing")
    }
}
