import SwiftUI
import UIKit

/// The share-sheet entry: Photos, Files or any app hands pictures and movies
/// to this controller. It scrubs them at once and then offers the clean copies.
final class ShareViewController: UIViewController {
    private let bench = Bench(scope: "share")

    override func viewDidLoad() {
        super.viewDidLoad()
        Face.register()
        // An extension gets much less memory than an app.
        bench.comparisonSize = 512
        view.backgroundColor = .black

        let root = BenchView(bench: bench) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        Task { @MainActor in
            await bench.add(providers: providers)
            // Wait for the first reading of each file, then scrub.
            for _ in 0..<200 where bench.items.contains(where: { $0.state == .reading }) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            await bench.scrubAll()
        }
    }
}
