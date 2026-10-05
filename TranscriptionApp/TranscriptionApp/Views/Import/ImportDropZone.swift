import SwiftUI
import UniformTypeIdentifiers

struct ImportDropZone: View {
    let onImport: ([URL]) -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down")
                .font(.title2)
                .foregroundStyle(isTargeted ? .blue : .secondary)

            Text("Drop audio files")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 80)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isTargeted ? Color.blue : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isTargeted ? Color.blue.opacity(0.05) : Color.clear)
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        // Les callbacks arrivent en parallele sur des files d'arriere-plan
        let collected = DroppedURLs()
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                defer { group.leave() }
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                let audioExtensions = ["m4a", "mp3", "wav", "aac", "flac", "ogg", "wma", "aiff", "mp4", "mov", "m4v"]
                if audioExtensions.contains(url.pathExtension.lowercased()) {
                    collected.append(url)
                }
            }
        }

        group.notify(queue: .main) {
            let urls = collected.urls
            if !urls.isEmpty {
                onImport(urls)
            }
        }

        return true
    }
}

private final class DroppedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) { lock.withLock { storage.append(url) } }
    var urls: [URL] { lock.withLock { storage } }
}
