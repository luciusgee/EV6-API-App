import XCTest
@testable import PreconditionKit

final class GuideTests: XCTestCase {
    func testEveryStepIsUniqueAndEveryReleasePointsAtRealSteps() {
        let ids = Guide.allSteps.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        for release in Guide.releases {
            XCTAssertEqual(release.steps.count, release.stepIds.count, "release \(release.number) names a missing step")
            XCTAssertFalse(release.steps.isEmpty)
        }
        XCTAssertEqual(Set(Guide.sections.map(\.id)).count, Guide.sections.count)
    }

    func testReleasesAreNewestFirstWithoutGaps() {
        let numbers = Guide.releases.map(\.number)
        XCTAssertEqual(numbers, numbers.sorted(by: >))
        XCTAssertEqual(Set(numbers).count, numbers.count)
        XCTAssertEqual(Guide.latest, numbers.first)
    }

    func testWhatsNewShowsOnlyUnseenUpdates() {
        XCTAssertEqual(Guide.unseen(since: Guide.latest), [])
        XCTAssertEqual(Guide.unseen(since: Guide.latest - 1).map(\.number), [Guide.latest])
        XCTAssertEqual(Guide.unseen(since: 0).count, Guide.releases.count)
    }

    func testStepsReadPlainly() {
        for step in Guide.allSteps {
            XCTAssertFalse(step.title.isEmpty)
            XCTAssertLessThan(step.body.count, 420, step.id)
            XCTAssertTrue(step.body.hasSuffix(".") || step.body.hasSuffix(")"), step.id)
        }
    }
}
