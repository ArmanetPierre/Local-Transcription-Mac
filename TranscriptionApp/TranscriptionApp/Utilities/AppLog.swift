import AppKit
import Foundation

/// Journal persistant : tout ce que l'app ecrit avec `print` (stdout/stderr) est
/// horodate et copie dans ~/Library/Logs/Voxa/Voxa.log (le conteneur de l'app en
/// version App Store). Sans lui, une app lancee depuis le Finder ne laisse aucune trace
/// quand un enregistrement ou une transcription echoue.
enum AppLog {
    static let directory: URL = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return library.appendingPathComponent("Logs/Voxa", isDirectory: true)
    }()

    static var fileURL: URL { directory.appendingPathComponent("Voxa.log") }

    private static let maxSize: UInt64 = 10_000_000
    private static var pipe: Pipe?
    private static var originalStdout: Int32 = -1

    /// A appeler une fois au lancement. Ne fait rien dans un terminal (Xcode, `script`) :
    /// la sortie y reste visible telle quelle, et on la copie quand meme dans le fichier.
    static func setUp() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        rotateIfNeeded()
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        handle.seekToEndOfFile()

        // stdout/stderr → tube → lecteur qui horodate, ecrit le fichier et renvoie
        // vers la sortie d'origine (console Xcode)
        let pipe = Pipe()
        self.pipe = pipe
        originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IOLBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        let original = originalStdout
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withFullTime, .withFractionalSeconds]
        var pending = Data()
        pipe.fileHandleForReading.readabilityHandler = { reader in
            let data = reader.availableData
            guard !data.isEmpty else { return }
            if original >= 0 {
                data.withUnsafeBytes { _ = write(original, $0.baseAddress, data.count) }
            }
            pending.append(data)
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                var out = Data("\(formatter.string(from: Date())) ".utf8)
                out.append(line)
                out.append(UInt8(ascii: "\n"))
                // Disque plein : surtout ne pas planter (write(_:) leve une exception ObjC)
                try? handle.write(contentsOf: out)
            }
        }

        let info = Bundle.main.infoDictionary
        print("===== Voxa \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?")) \(Bundle.main.bundleIdentifier ?? "") — macOS \(ProcessInfo.processInfo.operatingSystemVersionString) =====")
    }

    /// Montre le journal dans le Finder (menu Aide).
    static func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private static func rotateIfNeeded() {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? UInt64,
              size > maxSize else { return }
        let previous = directory.appendingPathComponent("Voxa.1.log")
        try? fm.removeItem(at: previous)
        try? fm.moveItem(at: fileURL, to: previous)
    }
}
