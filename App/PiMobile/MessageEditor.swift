import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The message box: it grows to six lines, then scrolls. Pasting an image attaches it to the message; with a keyboard (an
/// iPad's, or a Mac's), Return sends and ⌘Return starts a new line. (A SwiftUI text field can do neither.) The on-screen
/// keyboard's Return still starts a new line: Send is beside the box.
struct MessageEditor: UIViewRepresentable {
    @Binding var text: String
    /// Whether the box has the keyboard: set when the user taps in or out, and setting it false puts the keyboard away.
    @Binding var focused: Bool
    /// What it's called (the placeholder), for VoiceOver and UI tests.
    let label: String
    let send: () -> Void
    let paste: ([PastedImage]) -> Void

    static let lines: CGFloat = 6

    func makeUIView(context: Context) -> EditorView {
        let view = EditorView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        // Its padding and background are the SwiftUI view's.
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        return view
    }

    func updateUIView(_ view: EditorView, context: Context) {
        context.coordinator.editor = self
        view.send = send
        view.pasteImages = paste
        view.accessibilityLabel = label
        // Not while the keyboard composes a character (marked text): setting the text would end it.
        if view.text != text, view.markedTextRange == nil { view.text = text }
        if !focused, view.isFirstResponder {
            DispatchQueue.main.async { view.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: EditorView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let line = view.font?.lineHeight ?? 22
        let fits = view.sizeThatFits(CGSize(width: width.isFinite ? width : .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).height
        let most = ceil(line * Self.lines)
        // Past six lines it scrolls (until then it's as tall as its text, and scrolling would only jiggle it).
        if view.isScrollEnabled != (fits > most) {
            DispatchQueue.main.async { view.isScrollEnabled = fits > most }
        }
        return CGSize(width: width, height: min(max(fits, ceil(line)), most))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var editor: MessageEditor

        init(_ editor: MessageEditor) { self.editor = editor }

        func textViewDidChange(_ view: UITextView) {
            if editor.text != view.text { editor.text = view.text }
        }

        func textViewDidBeginEditing(_ view: UITextView) {
            if !editor.focused { editor.focused = true }
        }

        func textViewDidEndEditing(_ view: UITextView) {
            if editor.focused { editor.focused = false }
        }
    }

    final class EditorView: UITextView {
        var send: () -> Void = {}
        var pasteImages: ([PastedImage]) -> Void = { _ in }

        override var keyCommands: [UIKeyCommand]? {
            let send = UIKeyCommand(title: "Send", action: #selector(sendMessage), input: "\r")
            let newLine = UIKeyCommand(title: "New Line", action: #selector(insertNewLine), input: "\r", modifierFlags: .command)
            // Ahead of the text view's own Return.
            send.wantsPriorityOverSystemBehavior = true
            newLine.wantsPriorityOverSystemBehavior = true
            return [send, newLine] + (super.keyCommands ?? [])
        }

        @objc private func sendMessage() { send() }

        @objc private func insertNewLine() { insertText("\n") }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            // While the keyboard composes a character, Return is the keyboard's (it picks the character).
            if action == #selector(sendMessage) { return markedTextRange == nil }
            // (The text view says no to actions it doesn't know.)
            if action == #selector(insertNewLine) { return true }
            if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
            return super.canPerformAction(action, withSender: sender)
        }

        /// Images go with the message as files; anything else pastes as text.
        override func paste(_ sender: Any?) {
            let images = PastedImage.onPasteboard()
            if images.isEmpty { super.paste(sender) } else { pasteImages(images) }
        }
    }
}

/// An image pasted in the message box, as a file pi's read tool takes: PNG, JPEG or GIF as it is, anything else (HEIC,
/// TIFF) as a JPEG.
struct PastedImage {
    let data: Data
    let fileExtension: String

    /// The pasteboard's images, one per item that has one. (By their data: `items` gives UIImages, which would lose a
    /// screenshot's PNG.)
    static func onPasteboard() -> [PastedImage] {
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasImages else { return [] }
        return (0..<pasteboard.numberOfItems).compactMap { index in
            let item = IndexSet(integer: index)
            let types = pasteboard.types(forItemSet: item)?.first ?? []
            func data(_ type: String) -> Data? { pasteboard.data(forPasteboardType: type, inItemSet: item)?.first }
            for (type, fileExtension) in [(UTType.png, "png"), (.jpeg, "jpg"), (.gif, "gif")] where types.contains(type.identifier) {
                if let data = data(type.identifier) { return PastedImage(data: data, fileExtension: fileExtension) }
            }
            guard let other = types.first(where: { UTType($0)?.conforms(to: .image) == true }),
                  let jpeg = data(other).flatMap(UIImage.init(data:))?.jpegData(compressionQuality: 0.9) else { return nil }
            return PastedImage(data: jpeg, fileExtension: "jpg")
        }
    }
}
