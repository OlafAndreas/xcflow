import Foundation

/// `xcflow keys`: the stored App Store Connect keys, and which one this repo uses.
enum KeysCommand {
    static let usage = "Usage: xcflow keys [use <key id> | remove <key id>]"

    /// 0 ok, 2 error, 64 usage.
    static func run(
        arguments: [String],
        keys: any KeyStore = KeychainKeyStore(),
        pins: KeyPins? = nil,
        out: @Sendable (String) -> Void = { print($0) },
        err: @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) -> Int32 {
        let pins = pins ?? KeyPins.here(root: nil)
        do {
            switch arguments {
            case [], ["list"]:
                try list(keys: keys, pins: pins, out: out)
            case let command where command.count == 2 && command[0] == "use":
                guard try isStored(command[1], in: keys) else {
                    err("Key \(command[1]) isn't stored on this machine. Store it with: xcflow auth --key-id \(command[1]) --issuer-id <issuer> --p8 <path>.")
                    return 2
                }
                if let moved = try pins.moveLegacyPin() {
                    out(moved)
                }
                try pins.pin(command[1])
                out("Pinned this repo to key \(command[1]) on this machine.")
            case let command where command.count == 2 && command[0] == "remove":
                guard try isStored(command[1], in: keys) else {
                    err("Key \(command[1]) isn't stored on this machine.")
                    return 2
                }
                try keys.remove(keyID: command[1])
                out("Removed key \(command[1]) from the Keychain.")
                if (try? pins.pinned()) == command[1] {
                    out("This repo is still pinned to it. Pick another with: xcflow keys use <key id>.")
                }
            default:
                err(usage)
                return 64
            }
            return 0
        } catch {
            err(error.localizedDescription)
            return 2
        }
    }

    private static func isStored(_ keyID: String, in keys: any KeyStore) throws -> Bool {
        try keys.keys().contains { $0.keyID == keyID }
    }

    private static func list(keys: any KeyStore, pins: KeyPins, out: (String) -> Void) throws {
        let pinned = try pins.pinned()
        let stored = try keys.keys()
        if stored.isEmpty {
            out("No App Store Connect keys are stored. Store one with: xcflow auth --key-id <id> --p8 <path> [--issuer-id <issuer>].")
        }
        for key in stored {
            var line = "\(key.keyID == pinned ? "*" : " ") \(key.keyID)  \(key.isTeamKey ? "team" : "individual")"
            if let date = key.stored {
                line += "  stored \(dateFormatter.string(from: date))"
            }
            out(line)
        }
        if let pinned, !stored.contains(where: { $0.keyID == pinned }) {
            out("This repo uses key \(pinned), which isn't stored on this machine. Store it with: xcflow auth --key-id \(pinned) --issuer-id <issuer> --p8 <path>, or pick a stored key with: xcflow keys use <key id>.")
        }
    }

    private static var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
