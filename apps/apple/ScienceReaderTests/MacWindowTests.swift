#if targetEnvironment(macCatalyst)
import UIKit
import XCTest
@testable import ScienceReader

@MainActor
final class MacWindowTests: XCTestCase {
    func testSettingsClearsTheWorkspaceSelectionAndTheSamePaneCanBeChosenAgain() throws {
        let model = ReaderModel(configuration: nil)
        model.showWideMode(.library)
        let controller = MacToolbarController(model: model)
        let toolbar = NSToolbar(identifier: "mac-window-test")
        let group = try XCTUnwrap(controller.toolbar(toolbar, itemForItemIdentifier: .init("gradstep.modes"),
                                                     willBeInsertedIntoToolbar: true) as? NSToolbarItemGroup)
        let library = try XCTUnwrap(WideMode.allCases.firstIndex(of: .library))
        XCTAssertEqual(group.selectedIndex, library)
        model.tab = .settings
        controller.update(mode: .library, settingsShown: true)
        XCTAssertEqual(group.selectedIndex, -1, "Settings must leave the remembered workspace segment available to reselect")

        group.selectedIndex = library
        let action = try XCTUnwrap(group.action)
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: group.target, from: group, for: nil))
        XCTAssertEqual(model.tab, .library)
        XCTAssertEqual(model.wideMode, .library)
        controller.update(mode: .library, settingsShown: false)
        XCTAssertEqual(group.selectedIndex, library)
    }
}
#endif
