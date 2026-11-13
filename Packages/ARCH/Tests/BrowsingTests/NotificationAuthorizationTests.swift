// Arch's notification permission from macOS, against a system that records what it is asked: macOS asks only while it has not asked, overlapping requests share its question, a refusal or a bare build answers no without asking, the status follows the system, and System Settings opens at Arch's entry.
import Foundation
import Testing
import UserNotifications
@testable import Browsing

@MainActor @Suite struct NotificationAuthorizationTests {
    @Test func macOSAsksOnlyWhileItHasNotAsked() {
        let system = FakeNotificationSystem(status: .notDetermined)
        let authorization = NotificationAuthorization(system: system.system)
        #expect(authorization.status == .notDetermined)

        var answers: [Bool] = []
        authorization.request { answers.append($0) }
        authorization.request { answers.append($0) }
        #expect(system.requests == 1)
        #expect(answers == [true, true])
        #expect(authorization.status == .allowed)
    }

    @Test func overlappingRequestsShareOneQuestion() {
        let system = FakeNotificationSystem(status: .notDetermined)
        system.holdsQuestions = true
        system.grants = false
        let authorization = NotificationAuthorization(system: system.system)

        var answers: [Bool] = []
        authorization.request { answers.append($0) }
        authorization.request { answers.append($0) }
        #expect(system.requests == 1)
        #expect(answers.isEmpty)

        system.answerHeldQuestions()
        #expect(answers == [false, false])
        #expect(authorization.status == .denied)
    }

    @Test func aRefusalOrABareBuildAnswersNoWithoutAsking() {
        let system = FakeNotificationSystem(status: .denied)
        let authorization = NotificationAuthorization(system: system.system)
        var answers: [Bool] = []
        authorization.request { answers.append($0) }
        #expect(system.requests == 0)

        let bare = NotificationAuthorization(system: nil)
        #expect(bare.status == .unavailable)
        bare.request { answers.append($0) }
        bare.openSystemSettings()
        #expect(answers == [false, false])
        #expect(bare.status == .unavailable)
    }

    @Test func theStatusFollowsTheSystem() {
        let system = FakeNotificationSystem(status: .denied)
        let authorization = NotificationAuthorization(system: system.system)
        #expect(authorization.status == .denied)

        // The user turns notifications on in System Settings and comes back.
        system.status = .allowed
        authorization.refresh()
        #expect(authorization.status == .allowed)

        // A request reads the status again before it answers.
        system.status = .denied
        var answers: [Bool] = []
        authorization.request { answers.append($0) }
        #expect(answers == [false])
        #expect(authorization.status == .denied)
        #expect(system.requests == 0)
    }

    @Test func userNotificationsStatusesMapToArchs() {
        #expect(NotificationAuthorization.Status(UNAuthorizationStatus.notDetermined) == .notDetermined)
        #expect(NotificationAuthorization.Status(UNAuthorizationStatus.denied) == .denied)
        #expect(NotificationAuthorization.Status(UNAuthorizationStatus.authorized) == .allowed)
        #expect(NotificationAuthorization.Status(UNAuthorizationStatus.provisional) == .allowed)
    }

    @Test func systemSettingsOpensAtArchsEntry() {
        let system = FakeNotificationSystem(status: .denied)
        let authorization = NotificationAuthorization(system: system.system)
        authorization.openSystemSettings()
        #expect(system.opened.map(\.absoluteString) == ["x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=test.arch.notifications"])
    }
}

/// A notification system that answers at once, or holds its questions until the test answers them, and records the questions and the addresses it opens.
final class FakeNotificationSystem {
    var status: NotificationAuthorization.Status
    /// The user's answer when macOS asks.
    var grants = true
    /// Holds each question until `answerHeldQuestions()`.
    var holdsQuestions = false
    private(set) var requests = 0
    private(set) var opened: [URL] = []
    private var heldQuestions: [() -> Void] = []

    init(status: NotificationAuthorization.Status) {
        self.status = status
    }

    var system: NotificationAuthorization.System {
        NotificationAuthorization.System(
            readStatus: { completion in completion(self.status) },
            requestAuthorization: { completion in
                self.requests += 1
                let answer = {
                    self.status = self.grants ? .allowed : .denied
                    completion(self.grants)
                }
                if self.holdsQuestions { self.heldQuestions.append(answer) } else { answer() }
            },
            open: { self.opened.append($0) },
            bundleIdentifier: "test.arch.notifications"
        )
    }

    func answerHeldQuestions() {
        let questions = heldQuestions
        heldQuestions = []
        questions.forEach { $0() }
    }
}
