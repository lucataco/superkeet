import Foundation

struct AppVersion: Equatable {
    let shortVersion: String
    let buildVersion: String

    var displayString: String { "\(shortVersion) (\(buildVersion))" }

    static var current: AppVersion {
        let mainInfo = Bundle.main.infoDictionary ?? [:]
        if let version = mainInfo["CFBundleShortVersionString"] as? String, !version.isEmpty {
            return resolve(bundleInfo: mainInfo)
        }
        let developmentInfo: [String: Any]
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if let data = try? Data(contentsOf: sourceRoot.appendingPathComponent("Resources/Info.plist")),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let values = plist as? [String: Any] {
            developmentInfo = values
        } else {
            developmentInfo = [:]
        }
        return resolve(bundleInfo: mainInfo, developmentInfo: developmentInfo)
    }

    static func resolve(bundleInfo: [String: Any], developmentInfo: [String: Any] = [:]) -> AppVersion {
        for info in [bundleInfo, developmentInfo] {
            if let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty {
                let build = info["CFBundleVersion"] as? String
                return AppVersion(shortVersion: version, buildVersion: build.flatMap { $0.isEmpty ? nil : $0 } ?? version)
            }
        }
        return AppVersion(shortVersion: "1.0", buildVersion: "1.0")
    }
}
