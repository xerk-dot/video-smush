import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - UI

struct ContentView: View {
    @StateObject var m = Model()
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 10) {
            header
            clipList
            controls
            if m.running || m.lastOutput != nil { progressBlock }
            logBlock
        }
        .padding(14)
        .frame(minWidth: 680, minHeight: 620)
    }

    var header: some View {
        HStack {
            Text("Video Smush").font(.title2.bold())
            Spacer()
            if m.ffmpeg == nil {
                Label("ffmpeg not found", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
            } else if !m.clips.isEmpty {
                Text("\(m.clips.count) clips · \(fmtDur(m.totalDuration)) · \(fmtMB(m.totalBytes))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var clipList: some View {
        VStack(spacing: 0) {
            if m.clips.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Drag video files here").foregroundStyle(.secondary)
                    Text("order top → bottom is the join order").font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                List(selection: $m.selection) {
                    ForEach(Array(m.clips.enumerated()), id: \.element.id) { i, c in
                        HStack {
                            Text("\(i+1).").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.name).lineLimit(1)
                                Text("\(fmtDur(c.duration)) · \(fmtMB(c.bytes)) · \(c.width)×\(c.height)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.tag(c.id)
                    }
                    .onMove { src, dst in m.clips.move(fromOffsets: src, toOffset: dst) }
                }
                .frame(minHeight: 180)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(dropping ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(dropping ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: dropping ? 2 : 1))
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let item = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                       let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) {
                        urls.append(u)
                    }
                }
                urls.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                m.add(urls)
            }
            return true
        }
    }

    var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Button("Add…") { pick() }
                Button("Remove") { m.removeSelected() }.disabled(m.selection.isEmpty)
                Button("▲") { m.move(up: true) }.disabled(m.selection.isEmpty)
                Button("▼") { m.move(up: false) }.disabled(m.selection.isEmpty)
                Button("Sort by name") { m.sortByName() }.disabled(m.clips.count < 2)
                Button("Clear") { m.clips = []; m.selection = [] }.disabled(m.clips.isEmpty)
                Spacer()
            }
            HStack(spacing: 14) {
                Picker("", selection: $m.mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 300).labelsHidden()
                Spacer()
                HStack(spacing: 4) { Text("Width").font(.caption); TextField("", text: $m.widthText).frame(width: 52) }
                HStack(spacing: 4) { Text("fps").font(.caption); TextField("", text: $m.fpsText).frame(width: 36) }
            }
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    Text("Quality").font(.caption)
                    Slider(value: $m.crf, in: 18...32, step: 1).frame(width: 130)
                    Text("CRF \(Int(m.crf))").font(.caption.monospaced()).frame(width: 52, alignment: .leading)
                }.disabled(m.limitOn)
                HStack(spacing: 4) {
                    Text("Parallel").font(.caption)
                    Stepper(value: $m.parallel, in: 1...6, step: 1) { Text("\(Int(m.parallel))").font(.caption.monospaced()) }
                }
                Toggle("Cap size", isOn: $m.limitOn)
                TextField("MB", text: $m.limitMB).frame(width: 44).disabled(!m.limitOn)
                Text("MB").font(.caption).foregroundStyle(m.limitOn ? .primary : .secondary)
                Spacer()
            }
            HStack(spacing: 6) {
                Text("Save to").font(.caption)
                Button(m.outDir.lastPathComponent) { chooseDir() }
                if m.mode == .concat {
                    TextField("output name", text: $m.outName)
                }
                Spacer()
                Button(m.running ? "Working…" : "Smush") { m.run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(m.running || m.clips.isEmpty || m.ffmpeg == nil)
            }
        }
    }

    var progressBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: m.progress)
            HStack {
                Text(m.stage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let o = m.lastOutput, !m.running {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([o]) }
                        .font(.caption)
                }
            }
        }
    }

    var logBlock: some View {
        ScrollView {
            Text(m.log).font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .frame(height: 110)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
    }

    func pick() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        if p.runModal() == .OK {
            var u = p.urls
            u.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            m.add(u)
        }
    }
    func chooseDir() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        if p.runModal() == .OK, let u = p.url { m.outDir = u }
    }
}
