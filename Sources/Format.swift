import Foundation

func fmtDur(_ s: Double) -> String {
    guard s.isFinite, s > 0 else { return "—" }
    let t = Int(s.rounded())
    return String(format: "%d:%02d", t / 60, t % 60)
}
func fileSize(_ p: String) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.int64Value ?? 0
}
func fmtMB(_ b: Int64) -> String { String(format: "%.1f MB", Double(b) / 1_048_576) }
