import HealthKit

enum HealthQueryResult {
    static func isTemporarilyUnavailable(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == HKErrorDomain && error.code == HKError.Code.errorDatabaseInaccessible.rawValue
    }

    static func isNoData(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == HKErrorDomain && error.code == HKError.Code.errorNoData.rawValue
    }

    // Missing samples are an empty result. Locked data, permission failures,
    // and interrupted queries must remain errors, so old values are retained.
    static func read<Value>(noData fallback: Value, query: () async throws -> Value) async throws -> Value {
        do { return try await query() }
        catch {
            if isNoData(error) { return fallback }
            throw error
        }
    }
}
