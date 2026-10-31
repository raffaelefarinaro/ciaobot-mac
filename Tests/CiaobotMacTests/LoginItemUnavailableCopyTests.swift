import XCTest

@testable import CiaobotMac

/// The copy for every reason macOS cannot use this copy as a login item. Pure
/// text: no ServiceManagement call, no code-signing probe, and no window.
final class LoginItemUnavailableCopyTests: XCTestCase {
    private let causes: [LoginItemUnavailableCause] = [
        .bareExecutable,
        .notInApplications,
        .unsignedOrAdHoc,
        .notFoundBySystem,
    ]

    func testEveryCauseHasItsOwnTitleAndExplanation() {
        let titles = causes.map(LoginItemUnavailableCopy.title(for:))
        let explanations = causes.map(LoginItemUnavailableCopy.explanation(for:))

        XCTAssertEqual(Set(titles).count, causes.count, "Each cause must name itself: \(titles).")
        XCTAssertEqual(
            Set(explanations).count,
            causes.count,
            "Each cause must explain itself: \(explanations)."
        )
        for text in titles + explanations {
            XCTAssertFalse(text.isEmpty, "An empty row or alert would leave the user with nothing.")
            XCTAssertFalse(text.contains("\n"), "One row or one alert must not carry line breaks: \(text).")
        }
    }

    func testBareExecutableKeepsTheBundledAppWording() {
        XCTAssertEqual(LoginItemUnavailableCopy.title(for: .bareExecutable), "Start at Login Unavailable")
        XCTAssertEqual(
            LoginItemUnavailableCopy.explanation(for: .bareExecutable),
            SystemLoginItem.bareExecutableReason
        )
        XCTAssertTrue(LoginItemUnavailableCopy.explanation(for: .bareExecutable).contains("Ciaobot.app"))
        XCTAssertFalse(
            LoginItemUnavailableCopy.offersLoginItemsSettings(for: .bareExecutable),
            "No login item exists for a bare executable, so Login Items has nothing to allow."
        )
    }

    func testNotInApplicationsNamesTheOneNextStep() {
        let title = LoginItemUnavailableCopy.title(for: .notInApplications)
        let explanation = LoginItemUnavailableCopy.explanation(for: .notInApplications)

        XCTAssertTrue(title.contains("Applications"), title)
        XCTAssertTrue(explanation.contains("Applications"), explanation)
        XCTAssertTrue(
            explanation.contains("notarized") || explanation.contains("signed"),
            "The other fix (running the notarized release from Applications) must be stated: \(explanation)"
        )
        XCTAssertFalse(
            LoginItemUnavailableCopy.offersLoginItemsSettings(for: .notInApplications),
            "Moving the app is done in Finder, not in Login Items settings."
        )
    }

    func testUnsignedOrAdHocSaysThisBuildCannotBeALoginItem() {
        let title = LoginItemUnavailableCopy.title(for: .unsignedOrAdHoc)
        let explanation = LoginItemUnavailableCopy.explanation(for: .unsignedOrAdHoc)

        XCTAssertTrue(title.localizedCaseInsensitiveContains("signed"), title)
        XCTAssertTrue(explanation.contains("not signed"), explanation)
        XCTAssertTrue(explanation.contains("Developer ID"), explanation)
        XCTAssertTrue(
            explanation.contains("signed") && explanation.contains("release"),
            "The next step is the signed release, not a retry of this build: \(explanation)"
        )
        XCTAssertFalse(
            LoginItemUnavailableCopy.offersLoginItemsSettings(for: .unsignedOrAdHoc),
            "Settings cannot sign a build."
        )
    }

    func testNotFoundBySystemKeepsTodaysMessageAndOffersSettings() {
        XCTAssertEqual(
            LoginItemUnavailableCopy.explanation(for: .notFoundBySystem),
            SystemLoginItem.notFoundReason
        )
        XCTAssertTrue(
            LoginItemUnavailableCopy.explanation(for: .notFoundBySystem).contains("could not find")
        )
        XCTAssertTrue(
            LoginItemUnavailableCopy.offersLoginItemsSettings(for: .notFoundBySystem),
            "An installed, signed app macOS lost is the one case the Login Items list can settle."
        )
    }

    func testOnlyCausesWhereLoginItemsSettingsHelpsOfferTheAction() {
        let offering = causes.filter(LoginItemUnavailableCopy.offersLoginItemsSettings(for:))
        XCTAssertEqual(offering, [.notFoundBySystem])
    }
}
