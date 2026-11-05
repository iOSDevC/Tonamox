import Foundation
import os
import XCTest
import TonamoxCore
@testable import TonamoxImageGen

/// Image model records in the shared JSON file, in a folder whose path has a space.
final class CoreMLDiffusionModelStoreSharedTests: XCTestCase {
    private var root: URL!
    private var file: SharedRecordsFile!
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "CoreMLDiffusionModelStoreSharedTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let base = root.appending(path: "Library/Application Support/AuraLocal", directoryHint: .isDirectory)
        file = SharedRecordsFile(file: base.appending(path: "image-model-records.json"),
                                 lockFile: base.appending(path: "records.lock"))
        suiteName = "CoreMLDiffusionModelStoreSharedTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private static func model(_ name: String) -> CoreMLDiffusionModel {
        CoreMLDiffusionModel(
            id: "hf:o/\(name)/compiled", displayName: name, repoID: "o/\(name)", revision: "a", folder: "compiled",
            components: ["Unet.mlmodelc/"], approximateDownloadBytes: 900_000_000, imageSide: 512,
            licenseName: "mit", licenseURL: URL(fileURLWithPath: "/"), preferredComputeUnits: .gpu,
            recommendedSteps: 4, recommendedGuidance: 1)
    }

    func testMergeCopiesStandardRecordsOnceAndKeepsThem() throws {
        let local = CoreMLDiffusionModelStore(defaults: defaults, onChange: {})
        local.remember(Self.model("local"))
        let shared = CoreMLDiffusionModelStore(sharedFile: file, onChange: {})
        shared.remember(Self.model("shared"))

        let added = file.mergeOnce(from: defaults, keys: [CoreMLDiffusionModelStore.defaultsKey],
                                   flagKey: CoreMLDiffusionModelStore.mergedFlagKey)

        XCTAssertEqual(added, 1)
        XCTAssertEqual(shared.all.map(\.displayName),
                       [CoreMLDiffusionModel.stableDiffusion21Base.displayName, "local", "shared"])
        XCTAssertNotNil(defaults.dictionary(forKey: CoreMLDiffusionModelStore.defaultsKey))
        XCTAssertTrue(defaults.bool(forKey: CoreMLDiffusionModelStore.mergedFlagKey))
        XCTAssertEqual(file.mergeOnce(from: defaults, keys: [CoreMLDiffusionModelStore.defaultsKey],
                                      flagKey: CoreMLDiffusionModelStore.mergedFlagKey), 0)
    }

    func testTwoAppsShareRecordsAndNotifyOnlyOnChange() {
        let changes = OSAllocatedUnfairLock(initialState: 0)
        let first = CoreMLDiffusionModelStore(sharedFile: file, onChange: { changes.withLock { $0 += 1 } })
        let second = CoreMLDiffusionModelStore(sharedFile: file, onChange: { changes.withLock { $0 += 1 } })
        let model = Self.model("dreamshaper")

        first.remember(model)
        first.remember(model)
        XCTAssertEqual(second.model(id: model.id), model)
        second.forget(model)
        second.forget(model)

        XCTAssertNil(first.model(id: model.id))
        XCTAssertEqual(changes.withLock { $0 }, 2)
    }
}
