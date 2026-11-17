import Foundation

enum CLI {
    static func main(_ args: [String]) -> Never {
        var files: [URL] = []
        var job = Job(files: [], outDir: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop"))
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--width":  i += 1; job.width = Int(args[i]) ?? 1920
            case "--fps":    i += 1; job.fps = Int(args[i]) ?? 30
            case "--crf":    i += 1; job.crf = Int(args[i]) ?? 26
            case "--max-mb": i += 1; job.limitMB = Double(args[i])
            case "--out":    i += 1; job.outName = args[i]
            case "--dir":    i += 1; job.outDir = URL(fileURLWithPath: args[i])
            case "--jobs":   i += 1; job.parallel = max(1, Int(args[i]) ?? 2)
            case "--separate": job.concat = false
            default: files.append(URL(fileURLWithPath: a))
            }
            i += 1
        }
        job.files = files
        let ok = Engine.run(job,
            log:   { print($0) },
            stage: { print("* " + $0) },
            progress: { _ in })
        exit(ok == nil ? 1 : 0)
    }
}
