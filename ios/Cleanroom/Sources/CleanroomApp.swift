import SwiftUI

@main
struct CleanroomApp: App {
    @State private var bench = Bench(scope: "app")

    init() {
        Face.register()
    }

    var body: some Scene {
        WindowGroup {
            BenchView(bench: bench)
            #if DEBUG
                .task { await preload() }
            #endif
        }
    }

    #if DEBUG
    /// For screenshots in the simulator: CLEANROOM_PRELOAD names a folder of
    /// files to load, and CLEANROOM_AUTOSCRUB=1 scrubs them.
    private func preload() async {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["CLEANROOM_PRELOAD"],
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
        bench.add(files: names.sorted().map { URL(fileURLWithPath: folder).appendingPathComponent($0) })
        for _ in 0..<200 where bench.items.contains(where: { $0.state == .reading }) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if env["CLEANROOM_AUTOSCRUB"] == "1" { await bench.scrubAll() }
    }
    #endif
}
