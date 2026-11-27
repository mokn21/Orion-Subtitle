import XCTest
@testable import OrionSubtitles

final class TranslationRequestLedgerTests: XCTestCase {
	func testRemotePlayLifecycleGateAllowsOnlyOneStart() {
		var gate = RemotePlayLifecycleGate()
		let id = try! XCTUnwrap(gate.begin())
		XCTAssertNil(gate.begin())
		gate.markActive(id)
		XCTAssertNil(gate.begin())
	}

	func testRemotePlayLifecycleGateAllowsOneStopAndCleanRestart() {
		var gate = RemotePlayLifecycleGate()
		let id = try! XCTUnwrap(gate.begin())
		gate.markActive(id)
		XCTAssertEqual(gate.beginStop(), id)
		XCTAssertNil(gate.beginStop())
		gate.finishStop(id)
		XCTAssertNotNil(gate.begin())
	}

	func testRequestIsClaimedOnceAndCompletedOnce() {
        var ledger = TranslationRequestLedger()
        let id = UUID()

        ledger.enqueue(id)
        XCTAssertTrue(ledger.claim(id))
        XCTAssertFalse(ledger.claim(id))
        XCTAssertTrue(ledger.complete(id))
        XCTAssertFalse(ledger.complete(id))
        XCTAssertTrue(ledger.completed.contains(id))
    }

    func testCancelledRequestCanBeRequeuedWithoutCompleting() {
        var ledger = TranslationRequestLedger()
        let id = UUID()

        ledger.enqueue(id)
        XCTAssertTrue(ledger.claim(id))
        ledger.requeue(id)
        XCTAssertTrue(ledger.pending.contains(id))
        XCTAssertTrue(ledger.claim(id))
        XCTAssertTrue(ledger.complete(id))
    }

	func testCompletedRequestCannotBeEnqueuedAgain() {
		var ledger = TranslationRequestLedger()
        let id = UUID()

        ledger.enqueue(id)
        XCTAssertTrue(ledger.claim(id))
        XCTAssertTrue(ledger.complete(id))
        ledger.enqueue(id)

		XCTAssertFalse(ledger.pending.contains(id))
		XCTAssertFalse(ledger.claim(id))
	}

    func testCompletedRequestHistoryRemainsBounded() {
        var ledger = TranslationRequestLedger()
        var ids: [UUID] = []

        for _ in 0..<300 {
            let id = UUID()
            ids.append(id)
            ledger.enqueue(id)
            XCTAssertTrue(ledger.claim(id))
            XCTAssertTrue(ledger.complete(id))
        }

        XCTAssertEqual(ledger.completed.count, 256)
        XCTAssertFalse(ledger.completed.contains(ids[0]))
        XCTAssertTrue(ledger.completed.contains(ids[299]))
    }


    @MainActor
    func testTranslationBatchPublishesEachLineAsSoonAsItCompletes() async throws {
        let service = ImmediateTestTranslationService()
        var partialResults: [(Int, String)] = []

        let results = try await service.translateBatch(["Health", "Press X"]) { index, translated in
            partialResults.append((index, translated))
        }

        XCTAssertEqual(results, ["ar:Health", "ar:Press X"])
        XCTAssertEqual(partialResults.map(\.0), [0, 1])
        XCTAssertEqual(partialResults.map(\.1), ["ar:Health", "ar:Press X"])
    }

    func testTranslationHistoryPersistsAcrossStoreInstancesAndCanBeCleared() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("orion-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let firstStore = TranslationHistoryStore(fileURL: fileURL)
        firstStore.append(
            sourceText: "Press start",
            translatedText: "اضغط ابدأ",
            context: "Test Console",
            boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1),
            confidence: 0.95
        )

        let reopenedStore = TranslationHistoryStore(fileURL: fileURL)
        XCTAssertEqual(reopenedStore.entries.count, 1)
        XCTAssertEqual(reopenedStore.entries.first?.sourceText, "Press start")
        XCTAssertEqual(reopenedStore.entries.first?.translatedText, "اضغط ابدأ")
        XCTAssertEqual(reopenedStore.entries.first?.context, "Test Console")

        reopenedStore.clear()
        let clearedStore = TranslationHistoryStore(fileURL: fileURL)
        XCTAssertTrue(clearedStore.entries.isEmpty)
    }


    func testSecondOCRRegionDefaultsDisabledAndPersists() throws {
        let defaults = StreamSettings()
        XCTAssertFalse(defaults.translationSecondRegionEnabled)

        var configured = defaults
        configured.translationSecondRegionEnabled = true
        configured.translationSecondRegion = CaptureRegion(x: 0.52, y: 0.08, width: 0.42, height: 0.28)

        let encoded = try JSONEncoder().encode(configured)
        let decoded = try JSONDecoder().decode(StreamSettings.self, from: encoded)
        XCTAssertTrue(decoded.translationSecondRegionEnabled)
        XCTAssertEqual(decoded.translationSecondRegion, configured.translationSecondRegion)
    }

    func testLegacyStreamSettingsKeepSecondOCRRegionDisabled() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(StreamSettings())) as? [String: Any]
        )
        object.removeValue(forKey: "translationSecondRegionEnabled")
        object.removeValue(forKey: "translationSecondRegion")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(StreamSettings.self, from: legacyData)
        XCTAssertFalse(decoded.translationSecondRegionEnabled)
        XCTAssertEqual(decoded.translationSecondRegion, StreamSettings().translationSecondRegion)
    }


    @MainActor
    func testSecondOCRCoordinatorHasIndependentRegionAndLifecycle() throws {
        let primary = TranslationCoordinator(
            translator: ExternalAITranslationService()
        )
        primary.configureSecondary()
        let secondary = try XCTUnwrap(primary.secondaryCoordinator)
        XCTAssertFalse(primary === secondary)

        primary.region = CaptureRegion(x: 0.05, y: 0.05, width: 0.4, height: 0.4)
        secondary.region = CaptureRegion(x: 0.55, y: 0.5, width: 0.4, height: 0.4)
        XCTAssertNotEqual(primary.region, secondary.region)

        primary.secondaryEnabled = true
        primary.start()
        XCTAssertEqual(secondary.state, .running)
        primary.pause()
        XCTAssertEqual(secondary.state, .paused)
        primary.stop()
        XCTAssertEqual(secondary.state, .stopped)
    }


    func testVideoCoordinateMapperUsesAspectFillForZoomMode() {
        let viewSize = CGSize(width: 1024, height: 768)
        let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)

        let fit = VideoCoordinateMapper.displayRect(for: fullFrame, in: viewSize, mode: .fit)
        XCTAssertEqual(fit.width, 1024, accuracy: 0.01)
        XCTAssertEqual(fit.height, 576, accuracy: 0.01)
        XCTAssertEqual(fit.minY, 96, accuracy: 0.01)

        let zoom = VideoCoordinateMapper.displayRect(for: fullFrame, in: viewSize, mode: .zoom)
        XCTAssertGreaterThan(zoom.width, viewSize.width)
        XCTAssertEqual(zoom.height, viewSize.height, accuracy: 0.01)
        XCTAssertLessThan(zoom.minX, 0)
    }

	func testVideoAccessUnitSplitsThreeAndFourByteAnnexBStartCodes() {
		let bytes: [UInt8] = [
			0, 0, 0, 1, 0x67, 0x64, 0,
			0, 0, 1, 0x68, 0xee,
			0, 0, 0, 1, 0x65, 0x88, 0x84,
		]
		let ranges = bytes.withUnsafeBufferPointer { buffer in
			VideoDecoder.splitAnnexB(buffer.baseAddress!, count: buffer.count)
		}
			XCTAssertEqual(ranges.map { Array(bytes[$0]) }, [
				[0x67, 0x64],
			[0x68, 0xee],
			[0x65, 0x88, 0x84],
		])
	}

		func testVideoAccessUnitWithNoStartCodeProducesNoFrames() {
			let bytes: [UInt8] = [0x67, 0x64, 0, 0x65]
			let ranges = bytes.withUnsafeBufferPointer { buffer in
				VideoDecoder.splitAnnexB(buffer.baseAddress!, count: buffer.count)
			}
			XCTAssertTrue(ranges.isEmpty)
		}

		func testVisionCoordinatesMapToDisplayCoordinatesForNativeSixteenByNine() {
			let rect = VideoCoordinateMapper.displayRect(
				for: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
				in: CGSize(width: 1920, height: 1080)
			)
			XCTAssertEqual(rect.origin.x, 480, accuracy: 0.01)
			XCTAssertEqual(rect.origin.y, 270, accuracy: 0.01)
			XCTAssertEqual(rect.width, 960, accuracy: 0.01)
			XCTAssertEqual(rect.height, 540, accuracy: 0.01)
		}

		func testVisionCoordinatesExcludeHorizontalLetterboxing() {
			let rect = VideoCoordinateMapper.displayRect(
				for: CGRect(x: 0, y: 0, width: 1, height: 1),
				in: CGSize(width: 2000, height: 1000)
			)
			XCTAssertEqual(rect.minX, 111.111, accuracy: 0.01)
			XCTAssertEqual(rect.minY, 0, accuracy: 0.01)
			XCTAssertEqual(rect.width, 1777.778, accuracy: 0.01)
			XCTAssertEqual(rect.height, 1000, accuracy: 0.01)
		}

		func testVisionCoordinatesExcludeVerticalLetterboxing() {
			let rect = VideoCoordinateMapper.displayRect(
				for: CGRect(x: 0, y: 0, width: 1, height: 0.5),
				in: CGSize(width: 1000, height: 2000)
			)
			XCTAssertEqual(rect.minX, 0, accuracy: 0.01)
			XCTAssertEqual(rect.minY, 1000, accuracy: 0.01)
			XCTAssertEqual(rect.width, 1000, accuracy: 0.01)
			XCTAssertEqual(rect.height, 281.25, accuracy: 0.01)
		}

        func testOCRCropCoordinatesMapBackToOriginalFrameWithoutHorizontalMirroring() {
            let fullScreen = CaptureRegion.fullScreen
            let leftText = OCRCoordinateMapper.fullFrameRect(
                for: CGRect(x: 0.08, y: 0.2, width: 0.12, height: 0.06),
                in: fullScreen
            )
            XCTAssertEqual(leftText.minX, 0.08, accuracy: 0.0001)
            XCTAssertEqual(leftText.minY, 0.2, accuracy: 0.0001)

            let rightText = OCRCoordinateMapper.fullFrameRect(
                for: CGRect(x: 0.78, y: 0.2, width: 0.12, height: 0.06),
                in: fullScreen
            )
            XCTAssertEqual(rightText.minX, 0.78, accuracy: 0.0001)

            let crop = CaptureRegion(x: 0.2, y: 0.1, width: 0.5, height: 0.4)
            let mapped = OCRCoordinateMapper.fullFrameRect(
                for: CGRect(x: 0.1, y: 0.25, width: 0.2, height: 0.1),
                in: crop
            )
            XCTAssertEqual(mapped.minX, 0.25, accuracy: 0.0001)
            XCTAssertEqual(mapped.minY, 0.2, accuracy: 0.0001)
            XCTAssertEqual(mapped.width, 0.1, accuracy: 0.0001)
            XCTAssertEqual(mapped.height, 0.04, accuracy: 0.0001)
        }

		func testOCRResultPreservesMultipleTextsAndTheirBoxesInOrder() {
			let first = OCRTextObservation(text: "Health", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.05), confidence: 0.91)
			let second = OCRTextObservation(text: "Press X", boundingBox: CGRect(x: 0.4, y: 0.2, width: 0.3, height: 0.06), confidence: 0.88)
			let now = ContinuousClock.now
			let result = OCRResult(observations: [first, second], capturedAt: now, startedAt: now, finishedAt: now)
			XCTAssertEqual(result.text, "Health Press X")
			XCTAssertEqual(result.observations.map(\.text), ["Health", "Press X"])
			XCTAssertEqual(result.observations.map(\.boundingBox), [first.boundingBox, second.boundingBox])
		}
    func testLateTranslationRequiresSourceTextToRemainInLatestOCRFrame() {
        let original = OCRTextObservation(
            text: "Press Start",
            boundingBox: CGRect(x: 0.2, y: 0.3, width: 0.25, height: 0.08),
            confidence: 0.95
        )
        let stillVisible = OCRTextObservation(
            text: "Press Start",
            boundingBox: CGRect(x: 0.22, y: 0.31, width: 0.25, height: 0.08),
            confidence: 0.93
        )

        XCTAssertNotNil(TranslationCoordinator.currentObservation(for: original, among: [stillVisible]))
        XCTAssertNil(TranslationCoordinator.currentObservation(for: original, among: []))
        XCTAssertNil(TranslationCoordinator.currentObservation(
            for: original,
            among: [OCRTextObservation(
                text: "Continue",
                boundingBox: original.boundingBox,
                confidence: 0.99
            )]
        ))
    }

    func testLateTranslationUsesLatestOCRGeometryForSameSourceText() {
        let original = OCRTextObservation(
            text: "Press Start",
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.08),
            confidence: 0.8
        )
        let latest = OCRTextObservation(
            text: "Press Start",
            boundingBox: CGRect(x: 0.4, y: 0.5, width: 0.3, height: 0.1),
            confidence: 0.98
        )

        let current = TranslationCoordinator.currentObservation(for: original, among: [latest])
        XCTAssertEqual(current?.boundingBox, latest.boundingBox)
        XCTAssertEqual(current?.confidence, latest.confidence)
    }


	}


private struct ImmediateTestTranslationService: TextTranslationService {
    func translate(_ text: String) async throws -> String {
        "ar:\(text)"
    }

}
