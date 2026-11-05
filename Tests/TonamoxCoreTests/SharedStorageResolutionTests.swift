import Foundation
import Testing
@testable import TonamoxCore

/// The resolution table, on paths with spaces as the real ones have.
struct SharedStorageResolutionTests {
    private let support = URL(filePath: "/tmp/Tonamox Tests/Library/Application Support", directoryHint: .isDirectory)
    private let container = URL(filePath: "/tmp/Tonamox Tests/Group Containers/group x", directoryHint: .isDirectory)
    private let group = "group.io.iosdevc.tonamox"

    private func resolve(_ appGroup: String?, _ platform: StoragePlatform, container: URL?) -> SharedStorageResolution {
        SharedStorageResolution.resolve(appGroup: appGroup, platform: platform, containerURL: container,
                                        applicationSupport: support)
    }

    private func path(_ url: URL?) -> String? {
        url?.path(percentEncoded: false)
    }

    @Test func withoutAGroupEveryPlatformKeepsTodaysPaths() {
        for platform in [StoragePlatform.iOSFamily, .sandboxedMac(hasGroupEntitlement: true), .unsandboxedMac] {
            let resolution = resolve(nil, platform, container: container)
            #expect(resolution == SharedStorageResolution.standard(applicationSupport: support))
            #expect(resolution.downloadRecordsFile == nil && resolution.recordsLockFile == nil)
            #expect(resolution.keychainAccessGroup == nil && resolution.signalPrefix == nil)
        }
    }

    @Test func iOSWithAContainerMovesEverythingIntoTheGroup() {
        let resolution = resolve(group, .iOSFamily, container: container)

        #expect(resolution.scope == .appGroup(identifier: group, container: container))
        #expect(path(resolution.applicationSupport)
                == "/tmp/Tonamox Tests/Group Containers/group x/Library/Application Support/")
        #expect(path(resolution.privateApplicationSupport) == path(support))
        #expect(resolution.keychainAccessGroup == group)
        #expect(resolution.signalPrefix == group)
        #expect(path(resolution.downloadRecordsFile)
                == "/tmp/Tonamox Tests/Group Containers/group x/Library/Application Support/AuraLocal/download-records.json")
        #expect(path(resolution.imageRecordsFile)?.hasSuffix("AuraLocal/image-model-records.json") == true)
        #expect(path(resolution.recordsLockFile)?.hasSuffix("Application Support/AuraLocal/records.lock") == true)
        #expect(path(resolution.privateAuraLocalDirectory) == "/tmp/Tonamox Tests/Library/Application Support/AuraLocal/")
    }

    @Test func iOSWithoutAContainerStaysStandard() {
        #expect(resolve(group, .iOSFamily, container: nil) == .standard(applicationSupport: support))
    }

    @Test func sandboxedMacNeedsTheEntitlementAndKeepsTheKeychain() {
        let entitled = resolve(group, .sandboxedMac(hasGroupEntitlement: true), container: container)
        #expect(entitled.scope == .appGroup(identifier: group, container: container))
        #expect(entitled.keychainAccessGroup == nil)
        #expect(entitled.signalPrefix == group)

        let unentitled = resolve(group, .sandboxedMac(hasGroupEntitlement: false), container: container)
        #expect(unentitled == .standard(applicationSupport: support))
    }

    @Test func unsandboxedMacKeepsFilesUserWideAndSharesRecordsAndSignals() {
        let resolution = resolve(group, .unsandboxedMac, container: container)

        #expect(resolution.scope == .userWide(identifier: group))
        #expect(resolution.applicationSupport == support)
        #expect(resolution.privateApplicationSupport == nil)
        #expect(resolution.keychainAccessGroup == nil)
        #expect(resolution.signalPrefix == group)
        #expect(path(resolution.downloadRecordsFile)
                == "/tmp/Tonamox Tests/Library/Application Support/AuraLocal/download-records.json")
    }
}

/// Sealing, on configurator instances so nothing leaks into the process-wide configuration.
struct SharedStorageConfiguratorTests {
    private let support = URL(filePath: "/tmp/Tonamox Tests/Library/Application Support", directoryHint: .isDirectory)
    private let container = URL(filePath: "/tmp/Tonamox Tests/Group Containers/group x", directoryHint: .isDirectory)

    private func makeConfigurator(container: URL?) -> SharedStorageConfigurator {
        let support = support
        return SharedStorageConfigurator(environment: .init(platform: { _ in .iOSFamily },
                                                            containerURL: { _ in container },
                                                            applicationSupport: { support }))
    }

    @Test func readingStorageBeforeConfigureSealsStandard() {
        let configurator = makeConfigurator(container: container)

        let first = configurator.resolution(for: .conversations)
        let outcome = configurator.configure(appGroup: "group.a")

        #expect(first.scope == .standard)
        #expect(outcome.configuration == .ignored(current: .standard, firstUse: "conversations"))
        #expect(!outcome.sealedNow)
        #expect(configurator.resolution(for: .models) == first)
    }

    @Test func theSameGroupTwiceIsAppliedBothTimes() {
        let configurator = makeConfigurator(container: container)

        let first = configurator.configure(appGroup: "group.a")
        let second = configurator.configure(appGroup: "group.a")

        #expect(first.configuration == .applied(.appGroup(identifier: "group.a", container: container)))
        #expect(first.sealedNow)
        #expect(second.configuration == first.configuration)
        #expect(!second.sealedNow)
    }

    @Test func anotherGroupIsIgnored() {
        let configurator = makeConfigurator(container: container)
        _ = configurator.configure(appGroup: "group.a")

        let other = configurator.configure(appGroup: "group.b")

        #expect(other.configuration == .ignored(current: .appGroup(identifier: "group.a", container: container),
                                                firstUse: "configure(appGroup: group.a)"))
        #expect(configurator.resolution(for: .models).signalPrefix == "group.a")
    }

    @Test func anUnresolvedGroupStaysStandardAndAnswersTheSameAgain() {
        let configurator = makeConfigurator(container: nil)

        #expect(configurator.configure(appGroup: "group.a").configuration == .unavailable(appGroup: "group.a"))
        #expect(configurator.configure(appGroup: "group.a").configuration == .unavailable(appGroup: "group.a"))
        #expect(configurator.resolution(for: .records).scope == .standard)
    }

    @Test func sealedResolutionDoesNotSeal() {
        let configurator = makeConfigurator(container: container)

        #expect(configurator.sealedResolution == nil)
        #expect(configurator.configure(appGroup: "group.a").sealedNow)
    }

    @Test func concurrentConfigureAndReadsSeeOneResolution() async {
        let configurator = makeConfigurator(container: container)

        let seen = await withTaskGroup(of: SharedStorageResolution.self) { group in
            for index in 0..<200 {
                group.addTask {
                    index.isMultiple(of: 2)
                        ? configurator.configure(appGroup: "group.a").resolution
                        : configurator.resolution(for: .models)
                }
            }
            return await group.reduce(into: [SharedStorageResolution]()) { $0.append($1) }
        }

        #expect(seen.count == 200)
        #expect(Set(seen.map(\.applicationSupport)).count == 1)
        #expect(seen.allSatisfy { $0 == configurator.sealedResolution })
    }
}
