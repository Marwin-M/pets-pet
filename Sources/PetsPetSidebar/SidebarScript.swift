import Foundation

public enum SidebarScript {
    public static func load() throws -> String {
        // Packaged App resources first, then SwiftPM resources for isolated runs.
        if let url = Bundle.main.url(forResource: "Sidebar", withExtension: "js") {
            return try String(contentsOf: url, encoding: .utf8)
        }
        // SwiftPM's generated Bundle.module traps if a bundle is missing. Search
        // adjacent resource bundles explicitly so packaging errors stay recoverable.
        let containers = [Bundle.main.resourceURL, Bundle.main.bundleURL,
                          Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        for container in containers {
            let url = container.appendingPathComponent("PetsPet_PetsPetSidebar.bundle/Sidebar.js")
            if FileManager.default.isReadableFile(atPath: url.path) { return try String(contentsOf: url, encoding: .utf8) }
        }
        throw SidebarError.protocolError
    }

    public static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}
