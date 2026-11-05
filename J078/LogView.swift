import SwiftUI
import UIKit

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct LogView: View {
    @ObservedObject var ble: BLEManager
    @State private var shareItem: ShareItem?
    @State private var follow = true

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(ble.log) { entry in
                    LogRow(entry: entry)
                        .id(entry.id)
                }
                .listStyle(.plain)
                .onChange(of: ble.log.count) { _ in
                    if follow, let last = ble.log.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .navigationTitle("Log (\(ble.log.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button(follow ? "Pause" : "Follow") {
                        follow.toggle()
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button("Clear") {
                        ble.clearLog()
                    }
                    Button {
                        if let url = ble.exportLogFile() {
                            shareItem = ShareItem(url: url)
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(items: [item.url])
            }
        }
    }
}

struct LogRow: View {
    let entry: LogEntry

    private var kindColor: Color {
        switch entry.kind {
        case .rx: return .green
        case .tx: return .orange
        case .info: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(LogEntry.timeFormatter.string(from: entry.time))
                    .foregroundColor(.secondary)
                Text(entry.kind.rawValue)
                    .bold()
                    .foregroundColor(kindColor)
                Text(entry.channel)
                    .bold()
            }
            .font(.caption2.monospaced())

            if !entry.bytes.isEmpty {
                Text(J078.hex(entry.bytes))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            if !entry.note.isEmpty {
                Text(entry.note)
                    .font(.caption)
                    .foregroundColor(entry.kind == .info ? Color.primary : Color.blue)
            }
        }
        .padding(.vertical, 1)
    }
}

/// UIKit share sheet (lets you save the .txt to Files, AirDrop it, etc.).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        return UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
}
