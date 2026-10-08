import HealthKit
import XCTest
@testable import ZeroZeroFood

final class HealthQueryResultTests: XCTestCase {
    func testEmptyPredicateIsAValidZeroResult() async throws {
        let value = try await HealthQueryResult.read(noData: 0) {
            throw NSError(domain: HKErrorDomain, code: HKError.Code.errorNoData.rawValue)
        }
        XCTAssertEqual(value, 0)
        let samples = try await HealthQueryResult.read(noData: [Double]()) {
            throw NSError(domain: HKErrorDomain, code: HKError.Code.errorNoData.rawValue)
        }
        XCTAssertTrue(samples.isEmpty)
    }

    func testLockedHealthDataCannotEraseLastKnownValuesAsZero() async {
        do {
            _ = try await HealthQueryResult.read(noData: 0) {
                throw NSError(domain: HKErrorDomain, code: HKError.Code.errorDatabaseInaccessible.rawValue)
            }
            XCTFail("Locked Health data must remain a failure, not a zero total")
        } catch {
            XCTAssertTrue(HealthQueryResult.isTemporarilyUnavailable(error))
            XCTAssertEqual((error as NSError).domain, HKErrorDomain)
            XCTAssertEqual((error as NSError).code, HKError.Code.errorDatabaseInaccessible.rawValue)
        }
    }

    func testCancellationIsNotReportedAsMissingSamples() async {
        do {
            _ = try await HealthQueryResult.read(noData: 0) { throw CancellationError() }
            XCTFail("Cancellation must not replace readings with zero")
        } catch {
            XCTAssertTrue(error is CancellationError)
            XCTAssertFalse(HealthQueryResult.isTemporarilyUnavailable(error))
        }
    }
}
