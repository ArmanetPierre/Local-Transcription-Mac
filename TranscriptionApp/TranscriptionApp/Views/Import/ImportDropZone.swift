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
        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                defer { group.leave() }
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                let audioExtensions = ["m4a", "mp3", "wav", "aac", "flac", "ogg", "wma", "aiff", "mp4", "mov", "m4v"]
                if audioExtensions.contains(url.pathExtension.lowercased()) {
                    urls.append(url)
                }
            }
        }

        group.notify(queue: .main) {
            if !urls.isEmpty {
                onImport(urls)
            }
        }

        return true
    }
}
