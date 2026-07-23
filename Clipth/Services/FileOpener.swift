import AppKit
import UniformTypeIdentifiers

enum FileOpener {
    static func openWithChooser(url: URL) {
        let panel = NSOpenPanel()
        panel.title = L("file.openWithChooserTitleFormat", url.lastPathComponent)
        panel.prompt = L("file.openWithChooserPrompt")
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let appURL = panel.url {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { _, error in
                if let error = error {
                    DispatchQueue.main.async {
                        let alert = NSAlert(error: error)
                        alert.runModal()
                    }
                }
            }
        }
    }
}
