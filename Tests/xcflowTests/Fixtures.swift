import Foundation
@testable import xcflow

enum Fixtures {
    static let nightlyID = "00000000-0000-0000-0000-000000000001"
    static let releaseID = "00000000-0000-0000-0000-000000000002"

    static func workflow(id: String?, name: String, hour: Int = 5) -> JSON {
        var json: JSON = [
            "repository": "example-app",
            "xcodeVersion": "Latest Release",
            "macOsVersion": "Latest Release",
            "attributes": [
                "name": name,
                "description": "Runs the tests every night",
                "isEnabled": true,
                "clean": true,
                "containerFilePath": "Example.xcodeproj",
                "actions": [[
                    "actionType": "TEST",
                    "name": "Test - iOS",
                    "platform": "IOS",
                    "scheme": "Example",
                    "testConfiguration": [
                        "kind": "USE_SCHEME_SETTINGS",
                        "testDestinations": [[
                            "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
                            "deviceTypeName": "iPhone 17",
                            "kind": "SIMULATOR",
                            "runtimeIdentifier": "default",
                            "runtimeName": "Latest from Selected Xcode (iOS 26.0)"
                        ]]
                    ] as JSON
                ]],
                "scheduledStartCondition": [
                    "schedule": ["frequency": "DAILY", "hour": hour, "minute": 0, "timezone": "Europe/Oslo", "days": [String]()] as JSON,
                    "source": ["isAllMatch": false, "patterns": [["isPrefix": false, "pattern": "main"]]] as JSON
                ] as JSON,
                "branchStartCondition": NSNull()
            ] as JSON
        ]
        if let id {
            json["id"] = id
        }
        return json
    }

    static func makeFolder(_ files: [String: JSON]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "xcflow-tests-\(UUID().uuidString)/XcodeCloud")
        for (path, json) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        }
        return root
    }

    static func standard() throws -> URL {
        try makeFolder([
            "com.example.app/nightly-tests.json": workflow(id: nightlyID, name: "Nightly tests"),
            "com.example.app/release.json": workflow(id: releaseID, name: "Release")
        ])
    }
}

extension Fixtures {
    static func makeRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "xcflow-repo-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    static func makeProject(in root: URL, project: String) throws -> URL {
        let url = root.appending(path: project, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func writeManifest(in root: URL, project: String, productIDs: [String]) throws {
        let folder = try makeProject(in: root, project: project).appending(path: "xcshareddata/xcodecloud", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json: JSON = [
            "id": UUID().uuidString.lowercased(),
            "targets": productIDs.map { ["id": $0, "name": "Target"] as JSON }
        ]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appending(path: "manifest.json"))
    }
}
