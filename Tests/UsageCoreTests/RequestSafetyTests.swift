import Foundation
import Testing
@testable import UsageCore

@Suite struct UsageRequestSafety {
    @Test func usageChecksHaveNoPromptOrBody() throws {
        for url in [ClaudeSource.endpoint, CodexSource.endpoint] {
            let request = try HTTP.request(url, headers: ["Authorization": "Bearer test-only"])
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            #expect(request.url == url)
        }
    }

    @Test func generationAndUnapprovedDestinationsAreRejected() {
        for raw in [
            "https://api.openai.com/v1/responses",
            "https://api.anthropic.com/v1/messages",
            "https://chatgpt.com/backend-api/conversation",
            "https://example.com/backend-api/wham/usage",
            "http://chatgpt.com/backend-api/wham/usage",
            "https://chatgpt.com/backend-api/wham/usage?prompt=hello"
        ] {
            #expect(throws: UsageError.self) {
                try HTTP.request(URL(string: raw)!, headers: [:])
            }
        }
    }

    @Test func retryAfterAcceptsSecondsAndHTTPDates() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(HTTP.retryDelay("120", now: now) == 120)
        #expect(HTTP.retryDelay("Thu, 01 Jan 1970 00:02:00 GMT", now: now) == 120)
        #expect(HTTP.retryDelay("invalid", now: now) == nil)
        #expect(HTTP.retryDelay("NaN", now: now) == nil)
    }

    @Test func nonFiniteAndBooleanNumbersAreRejected() {
        #expect(JSON.double("NaN") == nil)
        #expect(JSON.double("infinity") == nil)
        #expect(JSON.double(true) == nil)
        #expect(JSON.date("inf") == nil)
    }
}
