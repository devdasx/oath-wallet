import Testing
import UIKit
@testable import Aperture

struct SendNoteEditorFocusTests {
    @Test
    @MainActor
    func focusRequestWaitsForCompletedPresentationAndRunsOnce() {
        var focusRequestCount = 0
        let observer = SendNotePresentationObserverController {
            focusRequestCount += 1
        }

        observer.loadViewIfNeeded()
        observer.viewWillAppear(false)
        #expect(focusRequestCount == 0)

        observer.viewDidAppear(false)
        #expect(focusRequestCount == 1)

        observer.viewDidAppear(false)
        #expect(focusRequestCount == 1)
    }

    @Test
    @MainActor
    func toolbarUsesNativeIconOnlyCloseAndConfirmRoles() async throws {
        let savedNotes = ListActionRecorder<String>()
        let host = try NativeListTestHost {
            SendNoteEditorScreen(initialNote: "  Native note  ") {
                savedNotes.actions.append($0)
            }
        }
        defer { host.close() }

        try await SendEntryUIProbe.wait(in: host.rootView) {
            guard let item = host.navigationController?.topViewController?.navigationItem else {
                return false
            }
            return nativeItems(item.leadingItemGroups.flatMap(\.barButtonItems)
                + (item.leftBarButtonItems ?? [])).count == 1
                && nativeItems(item.trailingItemGroups.flatMap(\.barButtonItems)
                    + (item.rightBarButtonItems ?? [])).count == 1
        }

        let navigation = try #require(host.navigationController)
        let navigationItem = try #require(navigation.topViewController?.navigationItem)
        // Role-based SwiftUI buttons become system bar items. UIKit does not
        // forward their SwiftUI accessibility identifiers to the bar item.
        let leadingItems = nativeItems(navigationItem.leadingItemGroups.flatMap(\.barButtonItems)
            + (navigationItem.leftBarButtonItems ?? []))
        let trailingItems = nativeItems(navigationItem.trailingItemGroups.flatMap(\.barButtonItems)
            + (navigationItem.rightBarButtonItems ?? []))
        let closeItem = try #require(leadingItems.first)
        let confirmItem = try #require(trailingItems.first)
        #expect(closeItem !== confirmItem)
        #expect(closeItem.action != nil)

        let forbiddenVisibleTitles = [
            WalletLocalization.string("common.close"),
            WalletLocalization.string("common.cancel"),
            WalletLocalization.string("common.done")
        ]
        let visibleToolbarLabels = SendEntryUIProbe.views(
            UILabel.self,
            in: navigation.navigationBar
        )
        .filter { !$0.isHidden && $0.alpha > 0 && $0.bounds.width > 0 }
        .compactMap(\.text)
        #expect(
            forbiddenVisibleTitles.allSatisfy {
                !visibleToolbarLabels.contains($0)
            }
        )

        let confirmAction = try #require(confirmItem.action)
        #expect(
            UIApplication.shared.sendAction(
                confirmAction,
                to: confirmItem.target,
                from: confirmItem,
                for: nil
            )
        )
        await Task.yield()
        #expect(savedNotes.actions == ["Native note"])
    }

    @MainActor
    private func nativeItems(_ items: [UIBarButtonItem]) -> [UIBarButtonItem] {
        var seen = Set<ObjectIdentifier>()
        return items.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }
}
