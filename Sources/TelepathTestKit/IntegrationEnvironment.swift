import Foundation

/// Gating for tests that need a live Cortex.
///
/// The default is to skip when no server is configured, so `swift test` works on a
/// laptop. That default is dangerous in CI: a job that forgets to start a Cortex
/// would report green having exercised no protocol code at all. Setting
/// `TELEPATH_REQUIRE_INTEGRATION=1` turns a missing server into a failure instead
/// of a skip.
public enum IntegrationEnvironment {
    public static var url: String? {
        ProcessInfo.processInfo.environment["TELEPATH_TEST_URL"]
    }

    /// CI sets this so that a missing `TELEPATH_TEST_URL` fails the run.
    public static var isRequired: Bool {
        ProcessInfo.processInfo.environment["TELEPATH_REQUIRE_INTEGRATION"] == "1"
    }

    /// Suites run when a server is configured, or when one was required and is
    /// missing — in the latter case so they can fail loudly rather than vanish.
    public static var shouldRun: Bool { url != nil || isRequired }

    public static func requireURL() throws -> String {
        guard let url else {
            throw ConfigurationError.missingURL
        }
        return url
    }

    public enum ConfigurationError: Error, CustomStringConvertible {
        case missingURL

        public var description: String {
            """
            TELEPATH_REQUIRE_INTEGRATION=1 but TELEPATH_TEST_URL is unset, so the \
            integration tests cannot reach a Cortex. Start one with \
            scripts/run-test-cortex.sh, or unset TELEPATH_REQUIRE_INTEGRATION to skip.
            """
        }
    }
}
