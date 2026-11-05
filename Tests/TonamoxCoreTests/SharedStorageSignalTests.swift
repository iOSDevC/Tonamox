import Foundation
import os
import Testing
@testable import TonamoxCore

/// The notify(3) path the apps use, on a unique name prefix and a private NotificationCenter.
struct SharedStorageSignalTests {

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func observe(_ center: NotificationCenter) -> (NSObjectProtocol, OSAllocatedUnfairLock<[SharedStorageChange]>) {
        let received = OSAllocatedUnfairLock(initialState: [SharedStorageChange]())
        let observer = center.addObserver(forName: TonamoxSharedStorage.didChangeNotification, object: nil,
                                          queue: nil) { notification in
            guard let change = TonamoxSharedStorage.change(of: notification) else { return }
            received.withLock { $0.append(change) }
        }
        return (observer, received)
    }

    @Test func aDarwinPostArrivesAsAChangeNotification() async throws {
        let prefix = "dev.auralocal.tests.\(UUID().uuidString)"
        let center = NotificationCenter()
        let (observer, received) = observe(center)
        defer { center.removeObserver(observer) }
        let tokens = SharedStorageSignal.observe(prefix: prefix, center: center,
                                                 queue: DispatchQueue(label: "SharedStorageSignalTests"))
        defer { SharedStorageSignal.cancel(tokens) }

        SharedStorageSignal.post(.conversations, prefix: prefix)
        try await waitUntil { !received.withLock { $0 }.isEmpty }

        #expect(tokens.count == SharedStorageChange.allCases.count)
        #expect(received.withLock { $0 } == [.conversations])
        #expect(SharedStorageSignal.name(of: .models, prefix: "group.x") == "group.x.models")
    }

    @Test func aLocalPostIsDeliveredOnceOnTheMainQueue() async throws {
        let center = NotificationCenter()
        let onMain = OSAllocatedUnfairLock(initialState: true)
        let observer = center.addObserver(forName: TonamoxSharedStorage.didChangeNotification, object: nil,
                                          queue: nil) { _ in
            let isMain = Thread.isMainThread
            onMain.withLock { $0 = $0 && isMain }
        }
        defer { center.removeObserver(observer) }
        let (counter, received) = observe(center)
        defer { center.removeObserver(counter) }

        SharedStorageSignal.postLocally(.documents, center: center)
        try await waitUntil { !received.withLock { $0 }.isEmpty }
        try await Task.sleep(for: .milliseconds(50))

        #expect(received.withLock { $0 } == [.documents])
        #expect(onMain.withLock { $0 })
    }

    @Test func changeReadsOnlyKnownPayloads() {
        let unknown = Notification(name: TonamoxSharedStorage.didChangeNotification, object: nil,
                                   userInfo: ["change": "settings"])

        #expect(TonamoxSharedStorage.change(of: SharedStorageSignal.notification(for: .models)) == .models)
        #expect(TonamoxSharedStorage.change(of: unknown) == nil)
    }
}
