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

		func testOCRResultPreservesMultipleTextsAndTheirBoxesInOrder() {
			let first = OCRTextObservation(text: "Health", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.05), confidence: 0.91)
			let second = OCRTextObservation(text: "Press X", boundingBox: CGRect(x: 0.4, y: 0.2, width: 0.3, height: 0.06), confidence: 0.88)
			let now = ContinuousClock.now
			let result = OCRResult(observations: [first, second], capturedAt: now, startedAt: now, finishedAt: now)
			XCTAssertEqual(result.text, "Health Press X")
			XCTAssertEqual(result.observations.map(\.text), ["Health", "Press X"])
			XCTAssertEqual(result.observations.map(\.boundingBox), [first.boundingBox, second.boundingBox])
		}
	}
