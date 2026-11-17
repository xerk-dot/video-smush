import Foundation

// MARK: - Engine (shared by UI and CLI)

struct Job {
    var files: [URL]
    var width: Int = 1920
    var fps: Int = 30
    var crf: Int = 26
    var limitMB: Double? = nil
    var concat: Bool = true
    var outDir: URL
    var outName: String = "combined.mp4"
    var parallel: Int = 2
}

enum Engine {
    static func probe(_ ffprobe: String, _ u: URL) -> (w: Int, h: Int, dur: Double) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffprobe)
        p.arguments = ["-v","error","-select_streams","v:0",
                       "-show_entries","stream=width,height",
                       "-show_entries","format=duration",
                       "-of","default=noprint_wrappers=1:nokey=1", u.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let parts = out.split(separator: "\n").map(String.init)
        guard parts.count >= 3 else { return (0,0,0) }
        return (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0, Double(parts[2]) ?? 0)
    }

    static func ffrun(_ bin: String, _ args: [String], duration: Double,
                      onProgress: @escaping (Double) -> Void) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-nostdin","-v","error","-progress","pipe:1","-nostats"] + args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        out.fileHandleForReading.readabilityHandler = { h in
            guard let s = String(data: h.availableData, encoding: .utf8), !s.isEmpty else { return }
            for line in s.split(separator: "\n") where line.hasPrefix("out_time_ms=") {
                if duration > 0, let v = Double(line.dropFirst(12)) {
                    onProgress(min(1, v / 1_000_000 / duration))
                }
            }
        }
        do { try p.run() } catch { return 1 }
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        return p.terminationStatus
    }

    static func unique(_ u: URL) -> URL {
        var out = u, n = 2
        let ext = u.pathExtension.isEmpty ? "mp4" : u.pathExtension
        while FileManager.default.fileExists(atPath: out.path) {
            out = u.deletingLastPathComponent()
                .appendingPathComponent(u.deletingPathExtension().lastPathComponent + " (\(n)).\(ext)")
            n += 1
        }
        return out
    }

    /// Returns the final output URL, or nil on failure.
    @discardableResult
    static func run(_ job: Job,
                    log: @escaping (String) -> Void,
                    stage: @escaping (String) -> Void,
                    progress: @escaping (Double) -> Void) -> URL? {
        guard let ffmpeg = Tool.find("ffmpeg"), let ffprobe = Tool.find("ffprobe") else {
            log("ffmpeg/ffprobe not found - install with: brew install ffmpeg"); return nil
        }
        guard !job.files.isEmpty else { return nil }

        var metas: [(URL, Int, Int, Double)] = []
        for f in job.files { let m = probe(ffprobe, f); metas.append((f, m.w, m.h, m.dur)) }
        let total = metas.reduce(0) { $0 + $1.3 }
        guard total > 0 else { log("could not read durations"); return nil }

        let w = max(16, job.width / 2 * 2)
        let h = max(16, Int((Double(w) * Double(metas[0].2) / Double(metas[0].1)).rounded()) / 2 * 2)
        log("Canvas \(w)x\(h) @ \(job.fps) fps - \(metas.count) clip(s), \(fmtDur(total))")
        let ar0 = Double(metas[0].1) / Double(metas[0].2)
        if metas.contains(where: { abs(Double($0.1)/Double($0.2) - ar0) > 0.002 }) {
            log("note: aspect ratios differ - all normalised to \(w)x\(h)")
        }

        var kbps: Int? = nil
        if let mb = job.limitMB {
            let budget = max(64_000.0, mb * 1_048_576 - 131_072)   // allow for container overhead
            kbps = max(40, Int(budget * 8 / total * 0.93 / 1000))
            log("Size cap \(Int(mb)) MB -> ~\(kbps!) kbps (two-pass)")
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vidsmush-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let lanes = max(1, min(job.parallel, metas.count))
        var parts = [URL?](repeating: nil, count: metas.count)
        var fracs = [Double](repeating: 0, count: metas.count)
        var failure: String? = nil
        let lock = NSLock()
        let weights = metas.map { $0.3 / total }

        func bump(_ i: Int, _ f: Double) {
            lock.lock()
            fracs[i] = f
            let overall = zip(fracs, weights).reduce(0) { $0 + $1.0 * $1.1 }
            lock.unlock()
            progress(overall)
        }

        stage(lanes > 1
              ? "Encoding \(metas.count) clip(s), \(lanes) at a time..."
              : "Encoding \(metas.count) clip(s)...")

        let group = DispatchGroup()
        let sem = DispatchSemaphore(value: lanes)
        let q = DispatchQueue(label: "vidsmush.encode", attributes: .concurrent)

        for (i, m) in metas.enumerated() {
            group.enter()
            q.async {
                sem.wait()
                defer { sem.signal(); group.leave() }
                lock.lock(); let aborted = failure != nil; lock.unlock()
                if aborted { return }

                let (url, _, _, dur) = m
                let base = url.deletingPathExtension().lastPathComponent
                let dest: URL
                if job.concat {
                    dest = tmp.appendingPathComponent(String(format: "p%03d.mp4", i))
                } else {
                    lock.lock()
                    dest = unique(job.outDir.appendingPathComponent(base + " (compressed).mp4"))
                    FileManager.default.createFile(atPath: dest.path, contents: nil)  // reserve the name
                    lock.unlock()
                }
                let vf = "scale=\(w):\(h),setsar=1,fps=\(job.fps)"
                var st: Int32 = 1

                if let br = kbps {
                    let lf = tmp.appendingPathComponent("pass\(i)").path
                    st = ffrun(ffmpeg, ["-y","-i",url.path,"-vf",vf,"-c:v","libx264","-b:v","\(br)k",
                                        "-preset","medium","-pix_fmt","yuv420p","-pass","1",
                                        "-passlogfile",lf,"-an","-f","mp4","/dev/null"],
                               duration: dur) { f in bump(i, f * 0.5) }
                    if st == 0 {
                        st = ffrun(ffmpeg, ["-y","-i",url.path,"-vf",vf,"-c:v","libx264","-b:v","\(br)k",
                                            "-preset","medium","-pix_fmt","yuv420p","-pass","2",
                                            "-passlogfile",lf,"-movflags","+faststart",dest.path],
                                   duration: dur) { f in bump(i, 0.5 + f * 0.5) }
                    }
                } else {
                    st = ffrun(ffmpeg, ["-y","-i",url.path,"-vf",vf,"-c:v","libx264","-crf","\(job.crf)",
                                        "-preset","medium","-pix_fmt","yuv420p",
                                        "-movflags","+faststart",dest.path],
                               duration: dur) { f in bump(i, f) }
                }

                guard st == 0 else {
                    lock.lock(); if failure == nil { failure = url.lastPathComponent }; lock.unlock()
                    return
                }
                bump(i, 1)
                lock.lock(); parts[i] = dest; lock.unlock()
                log("  ok \(url.lastPathComponent) -> \(fmtMB(fileSize(dest.path))) (was \(fmtMB(fileSize(url.path))))")
            }
        }
        group.wait()

        if let bad = failure { log("ffmpeg failed on \(bad)"); return nil }
        let ordered = parts.compactMap { $0 }
        guard ordered.count == metas.count else { log("some clips did not encode"); return nil }

        if job.concat {
            stage("Joining \(ordered.count) clips...")
            let list = tmp.appendingPathComponent("list.txt")
            let body = ordered.map { "file '" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                .joined(separator: "\n")
            try? body.write(to: list, atomically: true, encoding: .utf8)
            var nm = job.outName.isEmpty ? "combined.mp4" : job.outName
            if !nm.lowercased().hasSuffix(".mp4") { nm += ".mp4" }
            let final = unique(job.outDir.appendingPathComponent(nm))
            let st = ffrun(ffmpeg, ["-y","-f","concat","-safe","0","-i",list.path,
                                    "-c","copy","-movflags","+faststart",final.path],
                           duration: 0) { _ in }
            guard st == 0 else { log("join failed"); return nil }
            progress(1)
            log("Done -> \(final.lastPathComponent)  \(fmtMB(fileSize(final.path)))  \(fmtDur(total))")
            return final
        } else {
            progress(1)
            log("Done - \(ordered.count) file(s) in \(job.outDir.path)")
            return job.outDir
        }
    }
}
