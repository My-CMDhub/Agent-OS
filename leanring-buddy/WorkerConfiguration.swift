//
//  WorkerConfiguration.swift
//  leanring-buddy
//
//  Where the Cloudflare Worker lives, and the key that proves a request came
//  from this app. Both are read from UserDefaults, set by the owner with
//  `defaults write`, so neither a deployment URL nor a client key is ever in
//  source or in the binary.
//
//  Why a client key at all: the worker holds paid API keys, and a worker that
//  forwards any request it receives is an open proxy for them. Clicky's upstream
//  repo had exactly that reported (farzaa/clicky issue #34). The client key is
//  not a secret in the cryptographic sense — anyone with the app's preferences
//  can read it — but it turns "anyone who finds the URL" into "someone who has
//  this machine", and it can be rotated with one `wrangler secret put`.
//

import Foundation

nonisolated enum WorkerConfiguration {
    /// The string a fresh clone ships with. It never resolves, which is the point:
    /// an unconfigured build fails on DNS instead of talking to someone's worker.
    static let placeholderBaseURL = "https://your-worker-name.your-subdomain.workers.dev"

    static let baseURLDefaultsKey = "ClickyWorkerBaseURL"
    static let clientKeyDefaultsKey = "ClickyWorkerClientKey"
    static let clientKeyHeaderName = "X-Clicky-Client-Key"

    /// The configured base URL without a trailing slash, or the placeholder.
    static var baseURL: String {
        guard let configuredBaseURL = nonEmptyDefault(forKey: baseURLDefaultsKey) else {
            return placeholderBaseURL
        }
        return configuredBaseURL.hasSuffix("/") ? String(configuredBaseURL.dropLast()) : configuredBaseURL
    }

    static var clientKey: String? {
        nonEmptyDefault(forKey: clientKeyDefaultsKey)
    }

    /// Both halves are needed: a URL without a key is answered 401 on every route.
    static var isConfigured: Bool {
        baseURL != placeholderBaseURL && clientKey != nil
    }

    static func routeURL(_ routePath: String) -> URL {
        URL(string: baseURL + routePath)!
    }

    /// Adds the client key header when one is configured. Without one the request
    /// goes out bare and the worker refuses it, which is the honest failure.
    static func attachClientKey(to request: inout URLRequest) {
        if let clientKey {
            request.setValue(clientKey, forHTTPHeaderField: clientKeyHeaderName)
        }
    }

    private static func nonEmptyDefault(forKey defaultsKey: String) -> String? {
        let trimmedValue = UserDefaults.standard.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmedValue?.isEmpty ?? true) ? nil : trimmedValue
    }
}
