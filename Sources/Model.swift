import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct Clip: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var duration: Double = 0
    var bytes: Int64 = 0
    var width: Int = 0
    var height: Int = 0
    var name: String { url.lastPathComponent }
}

enum Mode: String, CaseIterable, Identifiable {
    case concat = "Join into one video"
    case separate = "Compress separately"
    var id: String { rawValue }
}

@MainActor
final class Model: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var selection: Set<UUID> = []
    @Published var mode: Mode = .concat
    @Published var widthText = "1920"
    @Published var fpsText = "30"
    @Published var crf = 26.0
    @Published var limitOn = false
    @Published var limitMB = "20"
    @Published var outName = "combined.mp4"
    @Published var parallel = 2.0
    @Published var outDir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
    @Published var log = ""
    @Published var running = false
    @Published var progress = 0.0
    @Published var stage = ""
    @Published var lastOutput: URL?

    let ffmpeg = Tool.find("ffmpeg")
    let ffprobe = Tool.find("ffprobe")

    var totalDuration: Double { clips.reduce(0) { $0 + $1.duration } }
    var totalBytes: Int64 { clips.reduce(0) { $0 + $1.bytes } }

    func say(_ s: String) { log += s + "\n" }

    func add(_ urls: [URL]) {
        guard let ffprobe else { say("⚠️ ffprobe not found — install ffmpeg (brew install ffmpeg)"); return }
        let exts: Set<String> = ["mp4","mov","m4v","mkv","avi","webm","mpg","mpeg","m2ts"]
        for u in urls where exts.contains(u.pathExtension.lowercased()) {
            if clips.contains(where: { $0.url == u }) { continue }
            var c = Clip(url: u)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffprobe)
            p.arguments = ["-v","error","-select_streams","v:0",
                           "-show_entries","stream=width,height",
                           "-show_entries","format=duration",
                           "-of","default=noprint_wrappers=1:nokey=1", u.path]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let parts = out.split(separator: "\n").map { String($0) }
            if parts.count >= 3 {
                c.width = Int(parts[0]) ?? 0
                c.height = Int(parts[1]) ?? 0
                c.duration = Double(parts[2]) ?? 0
            }
            c.bytes = fileSize(u.path)
            clips.append(c)
        }
        if clips.count == 1 || outName == "combined.mp4" {
            if let f = clips.first {
                let base = f.url.deletingPathExtension().lastPathComponent
                outName = clips.count > 1 ? "\(base) + \(clips.count - 1) more (combined).mp4"
                                          : "\(base) (compressed).mp4"
            }
        }
    }

    func move(up: Bool) {
        let idxs = clips.indices.filter { selection.contains(clips[$0].id) }
        guard !idxs.isEmpty else { return }
        for i in (up ? idxs : idxs.reversed()) {
            let j = up ? i - 1 : i + 1
            guard clips.indices.contains(j) else { continue }
            clips.swapAt(i, j)
        }
    }
    func removeSelected() { clips.removeAll { selection.contains($0.id) }; selection = [] }
    func sortByName() { clips.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }

    // MARK: Run

    func run() {
        guard ffmpeg != nil else { say("ffmpeg not found - install with: brew install ffmpeg"); return }
        guard !clips.isEmpty else { return }
        let job = Job(files: clips.map(\.url),
                      width: Int(widthText) ?? 1920,
                      fps: max(1, Int(fpsText) ?? 30),
                      crf: Int(crf.rounded()),
                      limitMB: limitOn ? Double(limitMB) : nil,
                      concat: mode == .concat,
                      outDir: outDir,
                      outName: outName,
                      parallel: Int(parallel.rounded()))
        running = true; progress = 0; log = ""; lastOutput = nil; stage = "Starting..."
        Task.detached {
            let result = Engine.run(job,
                log:      { m in Task { @MainActor in self.log += m + "\n" } },
                stage:    { m in Task { @MainActor in self.stage = m; self.log += m + "\n" } },
                progress: { v in Task { @MainActor in self.progress = min(1, max(0, v)) } })
            await MainActor.run {
                self.running = false
                if let r = result { self.lastOutput = r; self.stage = "Finished" }
                else { self.stage = "Failed - see log" }
            }
        }
    }

    func setProgress(_ v: Double) { progress = min(1, max(0, v)) }
    func setStage(_ s: String) { stage = s; log += s + "\n" }
}
