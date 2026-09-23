import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
@Suite(.serialized)
struct VersionHistorySettingsTests {
    @Test
    func catalogPreservesEveryPublishedReleaseInNewestFirstOrder() {
        #expect(Set(VersionHistoryCatalog.releases.map(\.id)).count == VersionHistoryCatalog.releases.count)
        #expect(VersionHistoryCatalog.releases.first?.displayVersion == "4.0.0 (72)")
        #expect(VersionHistoryCatalog.releases.first?.version == AppBundleMetadata.version)
        #expect(VersionHistoryCatalog.releases.first?.build == AppBundleMetadata.build)
        #expect(
            VersionHistoryCatalog.releases.map(\.version) == [
                "4.0.0",
                "3.5.9",
                "3.5.9",
                "3.5.9",
                "3.5.9",
                "3.5.9",
                "3.5.9",
                "3.5.8",
                "3.5.7",
                "3.5.6",
                "3.5.5",
                "3.5.5",
                "3.5.5",
                "3.5.5",
                "3.5.4",
                "3.5.4",
                "3.5.3",
                "3.5.2",
                "3.5.1",
                "3.5.0",
                "2.40.12",
                "2.40.11",
                "2.40.10",
                "2.40.09",
                "2.40.08",
                "2.40.04",
                "2.40.03",
                "2.40.01"
            ]
        )
        #expect(
            VersionHistoryCatalog.releases
                .flatMap(\.features)
                .count == 137
        )
    }

    @Test
    func everyFeatureHasAReadableTitleAndExplanatorySubtitle() {
        for release in VersionHistoryCatalog.releases {
            #expect(!release.features.isEmpty)
            #expect(Set(release.features.map(\.id)).count == release.features.count)

            for feature in release.features {
                #expect(!feature.titleKey.isEmpty)
                #expect(!feature.detailKey.isEmpty)
                #expect(
                    WalletLocalization.string(feature.titleKey)
                        != feature.titleKey
                )
                #expect(
                    WalletLocalization.string(feature.detailKey)
                        != feature.detailKey
                )
            }
        }
    }

    @Test(arguments: [
        NativeListTestLayout.phone,
        .pad,
        .largeTextRTL
    ])
    func aboutPushesVersionHistoryAsItsOwnDestination(
        layout: NativeListTestLayout
    ) async throws {
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                AboutSettingsView()
            }
        }
        defer { host.close() }

        let list = try await host.list {
            $0.numberOfSections == 3
                && $0.numberOfItems(inSection: 1) == 1
        }
        let navigation = try #require(host.navigationController)
        #expect(navigation.viewControllers.count == 1)

        try await host.selectNavigationRow(
            IndexPath(item: 0, section: 1),
            in: list
        )

        for _ in 0..<100 {
            host.rootView.layoutIfNeeded()
            if navigation.viewControllers.count == 2,
               navigation.transitionCoordinator == nil {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(navigation.viewControllers.count == 2)
        #expect(
            navigation.topViewController?.navigationItem.title?.isEmpty
                == false
        )
    }
}
