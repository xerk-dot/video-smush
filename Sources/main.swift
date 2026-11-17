import SwiftUI
import UniformTypeIdentifiers
import AppKit

@main
struct Entry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--cli" { CLI.main(Array(args.dropFirst())) }
        VidSmushApp.main()
    }
}

struct VidSmushApp: App {
    var body: some Scene {
        WindowGroup("Video Smush") { ContentView() }
            .windowResizability(.contentSize)
    }
}
