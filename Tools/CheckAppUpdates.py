#!/usr/bin/env python3
"""Host update checks: production model, disposable bundles and mocked Apple responses."""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='oath-app-updates-') as directory:
    work = Path(directory)
    sources = work/'Sources/Checks'
    sources.mkdir(parents=True)
    model = (ROOT/'OathAtmosphere/Home/OathAboutPage.swift').read_text()
    model = model[model.index('enum OathAppUpdateState:'):]
    (sources/'Model.swift').write_text('import Foundation\nimport Observation\nimport OathDiagnostics\n'+model)
    (sources/'Checks.swift').write_text(r'''
import Foundation
import OathDiagnostics

actor Calls {
    var count = 0
    func increment() { count += 1 }
}
@main enum Checks {
    static func payload(_ version: String, id: Int = OathAppUpdateLookup.appID, bundle: String = OathAppUpdateLookup.bundleID) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["results": [["trackId": id, "bundleId": bundle, "version": version]]])
    }
    static func response(_ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://itunes.apple.com/lookup")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        for (local, remote, expected) in [
            ("4.1.5", "4.1.6", OathAppUpdateState.available("4.1.6")),
            ("4.9", "4.10", .available("4.10")),
            ("4.1.5", "4.1.5", .current),
            ("4.1", "4.1.0", .current),
            ("4.1.5", "4.0.3", .current),
            ("4.1.5", "5.0", .available("5.0"))] {
            check(try OathAppUpdateLookup.result(data: payload(remote), installedVersion: local) == expected,
                  "Numeric version comparison must not offer older releases or compare build numbers")
        }
        check(try OathAppUpdateLookup.result(data: Data("{\"results\":[]}".utf8), installedVersion: "4.1.5") == .unavailable,
              "Missing regional listing is not an up-to-date claim")
        check(try OathAppUpdateLookup.result(data: payload("9.0", id: 1), installedVersion: "4.1.5") == .unavailable,
              "Different store identity cannot advertise an update")
        check(try OathAppUpdateLookup.result(data: payload("9.0", bundle: "other.app"), installedVersion: "4.1.5") == .unavailable,
              "Different bundle cannot advertise an update")
        for invalid in ["", "4..2", "4.beta", "5.0\n", "-1", String(repeating: "9", count: 50)] {
            do { _ = try OathAppUpdateLookup.result(data: payload(invalid), installedVersion: "4.1.5"); preconditionFailure("Invalid version accepted") }
            catch { checks += 1 }
        }
        do { _ = try OathAppUpdateLookup.result(data: Data("not JSON".utf8), installedVersion: "4.1.5"); preconditionFailure("Invalid payload accepted") }
        catch { checks += 1 }
        let request = OathAppUpdateLookup.request(region: "GB")
        let params = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        check(params.first { $0.name == "country" }?.value == "gb" && request.timeoutInterval == 10, "Bounded regional public lookup")
        check(OathAppUpdateLookup.request(region: "invalid").url?.query?.contains("country") == false, "Invalid country never enters request")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".bundle")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let info = ["CFBundleIdentifier": "fixture.bundle", "CFBundleShortVersionString": "6.7.8", "CFBundleVersion": "912"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: folder.appendingPathComponent("Info.plist"))
        let bundle = Bundle(url: folder)!
        let calls = Calls()
        let model = OathAppUpdateModel(bundle: bundle, region: "US") { request in
            await calls.increment()
            try await Task.sleep(for: .milliseconds(100))
            return (try payload("6.8.0"), response())
        }
        check(model.version == "6.7.8" && model.build == "912", "About reads both values from the installed bundle")
        let first = Task { await model.check() }
        for _ in 0..<100 where model.state != .checking { await Task.yield() }
        await model.check()
        await first.value
        let count = await calls.count
        check(count == 1 && model.state == .available("6.8.0"), "Concurrent checks coalesce and publish verified update")
        let failure = OathAppUpdateModel(bundle: bundle) { _ in (try payload("9.0"), response(503)) }
        await failure.check()
        check(failure.state == .unavailable, "HTTP failure cannot claim current or available")
        let offline = OathAppUpdateModel(bundle: bundle) { _ in throw URLError(.notConnectedToInternet) }
        await offline.check()
        check(offline.state == .unavailable, "Offline result offers a retry")
        let canceled = OathAppUpdateModel(bundle: bundle) { _ in try await Task.sleep(for: .seconds(10)); return (try payload("9.0"), response()) }
        let task = Task { await canceled.check() }
        for _ in 0..<100 where canceled.state != .checking { await Task.yield() }
        task.cancel(); await task.value
        check(canceled.state == .idle, "Leaving About cancels without reporting a failed update")
        print("Passed \(checks) app update checks: actual bundle metadata, numeric versions, identity, absent listings, malformed data, HTTP/offline failure, cancellation and coalescing.")
    }
}
''')
    (work/'Package.swift').write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "Checks", platforms: [.macOS(.v14)], dependencies: [.package(path: %s)],
    targets: [.executableTarget(name: "Checks", dependencies: ["OathDiagnostics"])], swiftLanguageModes: [.v6])
''' % json.dumps(str(ROOT/'Packages/OathDiagnostics')))
    subprocess.run(['swift','run','--package-path',str(work),'--scratch-path','/tmp/oath-app-update-checks','Checks'],check=True)
