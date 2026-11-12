import Foundation

enum XMP {
    /// Namespaces that only hold HDR gain map parameters. An XMP packet on a
    /// gain map picture stays when it uses nothing else.
    static let gainMapNamespaces: Set<String> = [
        "adobe:ns:meta/",
        "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
        "http://ns.apple.com/HDRGainMap/1.0/",
        "http://ns.apple.com/pixeldatainfo/1.0/",
        "http://ns.adobe.com/hdr-gain-map/1.0/",
    ]

    static func text(_ packet: Data) -> String {
        String(decoding: packet, as: UTF8.self)
    }

    /// Every (prefix, URI) pair declared in the packet.
    static func declarations(_ packet: Data) -> [(prefix: String, uri: String)] {
        let source = text(packet)
        guard let regex = try? NSRegularExpression(pattern: #"xmlns:([A-Za-z0-9_\-]+)\s*=\s*["']([^"']*)["']"#) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard let p = Range(match.range(at: 1), in: source), let u = Range(match.range(at: 2), in: source) else { return nil }
            return (String(source[p]), String(source[u]))
        }
    }

    static func describesOnlyGainMap(_ packet: Data) -> Bool {
        let uris = Set(declarations(packet).map(\.uri))
        return !uris.isEmpty && packet.count <= 16_384 && uris.isSubset(of: gainMapNamespaces)
    }

    static func summary(_ packet: Data) -> String {
        let skip: Set<String> = ["x", "rdf", "xml"]
        var seen: [String] = []
        for d in declarations(packet) where !skip.contains(d.prefix) && !seen.contains(d.prefix) { seen.append(d.prefix) }
        return seen.isEmpty ? "XMP packet" : "XMP packet with " + seen.prefix(8).joined(separator: ", ")
    }
}
