import EventKit
import Foundation
import UserNotifications

/// Optional "meeting starting — record it?" notifications, driven by the
/// user's calendar. Opt-in (Settings → Meetings), read-only, polled locally.
@MainActor
final class ReminderCenter: NSObject, UNUserNotificationCenterDelegate {
    var onStartRecording: (() -> Void)?

    private let eventStore = EKEventStore()
    private var pollTask: Task<Void, Never>?
    private var notifiedEventIDs: Set<String> = []
    private var notificationsAuthorized = false
    private var calendarAuthorized = false

    func start() {
        guard pollTask == nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let record = UNNotificationAction(
            identifier: "RECORD",
            title: L10n.t("Start Recording", "녹음 시작"),
            options: [])
        let category = UNNotificationCategory(
            identifier: "MEETING_REMINDER",
            actions: [record],
            intentIdentifiers: [])
        center.setNotificationCategories([category])

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func poll() async {
        guard UserDefaults.standard.bool(forKey: "meetingReminders") else { return }

        if !calendarAuthorized {
            calendarAuthorized = (try? await eventStore.requestFullAccessToEvents()) ?? false
            guard calendarAuthorized else { return }
        }
        if !notificationsAuthorized {
            notificationsAuthorized = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])) ?? false
            guard notificationsAuthorized else { return }
        }

        let now = Date()
        let predicate = eventStore.predicateForEvents(
            withStart: now.addingTimeInterval(-30),
            end: now.addingTimeInterval(120),
            calendars: nil)
        for event in eventStore.events(matching: predicate) where !event.isAllDay {
            guard let id = event.eventIdentifier, !notifiedEventIDs.contains(id),
                  let start = event.startDate,
                  start.timeIntervalSince(now) < 90, start.timeIntervalSince(now) > -30
            else { continue }
            notifiedEventIDs.insert(id)

            let content = UNMutableNotificationContent()
            content.title = event.title ?? L10n.t("Meeting", "회의")
            content.body = L10n.t("Starting now — record it?", "지금 시작합니다 — 녹음할까요?")
            content.categoryIdentifier = "MEETING_REMINDER"
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        if action == "RECORD" || action == UNNotificationDefaultActionIdentifier {
            await MainActor.run { self.onStartRecording?() }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
