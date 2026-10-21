import Foundation

/// Which products the build commands act on: the repo's XcodeCloud folders, one product, or everything.
enum BuildScope {
    static func resolve(root: URL, product: String?, all: Bool) -> ProductScope {
        { client in
            let products = try await client.products()
            if let product {
                let matches = products.filter { $0.bundleID == product || $0.name.caseInsensitiveCompare(product) == .orderedSame || $0.id == product }
                guard !matches.isEmpty else {
                    throw ToolError.notFound("No product matches \"\(product)\". Products: \(products.map(\.label).joined(separator: ", ")).")
                }
                return matches
            }
            if all {
                return products
            }
            let folders = folders(in: root)
            guard !folders.isEmpty else {
                throw ToolError.refused("No products in \(root.lastPathComponent)/. Run from the repo root, or pass --product <bundle id> or --all.")
            }
            var scoped: [Product] = []
            for folder in folders {
                let matches = products.filter { $0.bundleID == folder }
                guard !matches.isEmpty else {
                    throw ToolError.refused("\(root.lastPathComponent)/\(folder) matches no product this key can see. Check the bundle id and the key's team, or pass --product or --all.")
                }
                scoped += matches
            }
            return scoped
        }
    }

    static func folders(in root: URL) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted()
    }
}
