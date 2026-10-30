#!/usr/bin/env python3
"""Validate original artwork, shipping icon metadata and selection logic on macOS.

UIKit is a controlled fake for state/failure checks; this does not claim actual
SpringBoard icon switching. Pass --app to also check a compiled iOS app bundle.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path)
args = parser.parse_args()
manifest = json.loads((ROOT / 'Design/AppIcons/icon-manifest.json').read_text())
assets = ROOT / 'OathApp/Assets.xcassets'

with tempfile.TemporaryDirectory(prefix='oath-app-icons-') as temporary:
    work = Path(temporary)
    settings = (ROOT / 'OathAtmosphere/Shared/OathAppSettings.swift').read_text()
    methods = settings[settings.index('    func selectAppIcon('):settings.index('    func selectLockDelay(')]
    (work / 'Checks.swift').write_text('''
import Foundation

enum TestFailure: Error { case rejected }
@MainActor final class UIApplication {
    static let shared = UIApplication()
    enum State { case active, background }
    var applicationState = State.active
    var supportsAlternateIcons = true
    var alternateIconName: String?
    var requests: [String?] = []
    var fail = false
    var pause = false
    var completion: CheckedContinuation<Void, Error>?
    func setAlternateIconName(_ name: String?) async throws {
        requests.append(name)
        if fail { throw TestFailure.rejected }
        if pause { try await withCheckedThrowingContinuation { completion = $0 } }
        alternateIconName = name
    }
}
enum OathDiagnostics {
    @TaskLocal static var operationID: UUID?
    @MainActor static var failures = 0
    @MainActor static func record(_ error: Error, component: String, operation: String) {
        precondition(operationID != nil)
        failures += 1
    }
}
@MainActor final class OathHaptics {
    static let shared = OathHaptics()
    enum Event { case success }
    var successes = 0
    func play(_ event: Event) { successes += 1 }
}
extension OathAppIcon {
    @MainActor static var current: Self? { choice(forAlternateName: UIApplication.shared.alternateIconName) }
}
@MainActor final class OathAppSettings {
    var appIcon = OathAppIcon.current
    var changingAppIcon = false
    private var attemptedRetiredIconReset = false
    var showsError = false
    var saved: [String: String] = [:]
    private func save(_ key: String, value: String) { saved[key] = value }
''' + methods + '''
}
@main enum Checks {
    @MainActor static func main() async throws {
        let os = UIApplication.shared
        let settings = OathAppSettings()
        precondition(settings.appIcon == .signalBlue)
        for icon in OathAppIcon.allCases {
            try await settings.selectAppIcon(icon)
            precondition(settings.appIcon == icon)
            precondition(os.alternateIconName == icon.alternateName)
            precondition(OathAppIcon.current == icon)
        }
        try await settings.selectAppIcon(.signalBlue)
        precondition(os.alternateIconName == nil)
        precondition(settings.saved["appIcon"] == "signal-blue")
        let requests = os.requests.count
        try await settings.selectAppIcon(.signalBlue)
        precondition(os.requests.count == requests, "No redundant system prompt")

        os.fail = true
        do { try await settings.selectAppIcon(.obsidian); fatalError("Expected rejection") }
        catch TestFailure.rejected { }
        precondition(settings.appIcon == .signalBlue && !settings.changingAppIcon)
        precondition(settings.saved["appIcon"] == "signal-blue")
        os.fail = false

        os.pause = true
        let change = Task { try await settings.selectAppIcon(.glacier) }
        while os.completion == nil { await Task.yield() }
        precondition(settings.appIcon == .signalBlue, "No premature selected checkmark")
        let inFlightCount = os.requests.count
        try await settings.selectAppIcon(.ember)
        precondition(os.requests.count == inFlightCount, "Concurrent changes must serialize")
        os.completion?.resume(); os.completion = nil
        try await change.value
        precondition(settings.appIcon == .glacier)
        os.pause = false
        let relaunched = OathAppSettings()
        await relaunched.refreshAppIcon()
        precondition(relaunched.appIcon == .glacier && os.requests.count == inFlightCount)

        for retired in ["AppIconLight", "AppIconDark", "AppIconTinted", "unknown-retired-icon"] {
            os.alternateIconName = retired
            let upgraded = OathAppSettings()
            precondition(upgraded.appIcon == nil)
            os.applicationState = .background
            let before = os.requests.count
            await upgraded.refreshAppIcon()
            precondition(os.requests.count == before)
            os.applicationState = .active
            let haptics = OathHaptics.shared.successes
            await upgraded.refreshAppIcon()
            precondition(os.alternateIconName == nil && upgraded.appIcon == .signalBlue)
            precondition(OathHaptics.shared.successes == haptics, "No launch haptic")
            await upgraded.refreshAppIcon()
            precondition(os.requests.count == before + 1)
        }
        os.alternateIconName = "AppIconDark"; os.fail = true
        let failedReset = OathAppSettings()
        await failedReset.refreshAppIcon()
        precondition(failedReset.showsError && failedReset.appIcon == nil)
        precondition(OathDiagnostics.failures == 1)
        let failedCount = os.requests.count
        await failedReset.refreshAppIcon()
        precondition(os.requests.count == failedCount, "Failed auto-reset must not loop")
        os.fail = false
        try await failedReset.selectAppIcon(.signalBlue)
        precondition(failedReset.appIcon == .signalBlue, "Explicit retry still works")

        os.supportsAlternateIcons = false
        let before = os.requests.count
        try await settings.selectAppIcon(.titanium)
        precondition(os.requests.count == before)
        let metadata = OathAppIcon.allCases.map {
            ["id": $0.rawValue, "title": $0.title, "titleKey": $0.titleKey.rawValue, "asset": $0.assetName, "preview": $0.preview]
        }
        print(String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self))
    }
}
''')
    binary = work / 'checks'
    subprocess.run(['swiftc', '-swift-version', '6', str(ROOT / 'OathAtmosphere/Localization/OathStringKey.swift'),
                    str(ROOT / 'OathAtmosphere/Preferences/OathAppIcon.swift'),
                    str(work / 'Checks.swift'), '-o', str(binary)], check=True)
    rows = json.loads(subprocess.check_output([str(binary)], text=True, timeout=30))

assert len(rows) == len(manifest['icons']) == 10
assert rows[0]['id'] == manifest['default_icon_id']
catalog = json.loads((ROOT / 'OathApp/Resources/Localizable.xcstrings').read_text())['strings']
locales = {row['code'] for row in json.loads((ROOT / 'Design/Localization/languages.json').read_text())}
assert len({row['titleKey'] for row in rows}) == 10
picker = (ROOT / 'OathAtmosphere/Preferences/OathPreferencesPages.swift').read_text()
summary = (ROOT / 'OathAtmosphere/Home/OathWalletSheets.swift').read_text()
assert 'title: strings.text(icon.titleKey)' in picker
assert 'settings.appIcon.map { strings.text($0.titleKey) }' in summary
assert 'strings.invariant(icon.title)' not in picker
assert 'strings.invariant($0.title)' not in summary
for row, icon in zip(rows, manifest['icons']):
    assert row['id'] == icon['id'] and row['title'] == icon['display_name']
    assert row['titleKey'] == 'app_icon.' + row['id'].replace('-', '_')
    titles = catalog[row['titleKey']]['localizations']
    assert set(titles) == locales and titles['en']['stringUnit']['value'] == row['title']
    assert all(value['stringUnit']['state'] == 'translated' and value['stringUnit']['value'].strip() for value in titles.values())
    assert (row['asset'] == 'AppIcon') == icon['is_default']
    for folder in [assets / (row['asset'] + '.appiconset'), assets / (row['preview'] + '.imageset')]:
        content = json.loads((folder / 'Contents.json').read_text())
        assert len(content['images']) == 1
        entry = content['images'][0]
        png = (folder / entry['filename']).read_bytes()
        assert hashlib.sha256(png).hexdigest() == icon['assets']['png']['sha256'], str(folder)
        assert png[:8] == b'\x89PNG\r\n\x1a\n'
        assert struct.unpack('>IIBB', png[16:26]) == (1024, 1024, 8, 2), 'Expect 1024px opaque RGB'
        if folder.suffix == '.appiconset':
            assert entry['idiom'] == 'universal' and entry['platform'] == 'ios' and entry['size'] == '1024x1024'
assert {p.stem for p in assets.glob('*.appiconset') if p.is_dir()} == {r['asset'] for r in rows}
assert {p.stem for p in assets.glob('IconPreview-*.imageset') if p.is_dir()} == {r['preview'] for r in rows}
alternates = ' '.join(r['asset'] for r in rows[1:])
assert (ROOT / 'project.yml').read_text().count(alternates) == 1
assert (ROOT / 'OathAtmosphere.xcodeproj/project.pbxproj').read_text().count(alternates) == 2
print('Passed: 10 exact original icons/previews; default, all alternatives, reset, upgrade, failure, concurrency and relaunch selection checks (mock UIKit).')

if args.app:
    info = plistlib.loads((args.app / 'Info.plist').read_bytes())
    expected = {r['asset'] for r in rows[1:]}
    for key in ['CFBundleIcons', 'CFBundleIcons~ipad']:
        icons = info[key]
        assert icons['CFBundlePrimaryIcon']['CFBundleIconName'] == 'AppIcon'
        assert set(icons['CFBundleAlternateIcons']) == expected
        assert all(value['CFBundleIconName'] == key for key, value in icons['CFBundleAlternateIcons'].items())
    compiled = json.loads(subprocess.check_output(['xcrun', 'assetutil', '--info', str(args.app / 'Assets.car')]))
    names = {item.get('Name') for item in compiled}
    assert {r['preview'] for r in rows} <= names
    assert not {'IconPreview-original', 'IconPreview-light', 'IconPreview-dark', 'IconPreview-monochrome'} & names
    print('Passed: compiled iPhone/iPad icon declarations and all 10 Settings previews; no retired previews.')
