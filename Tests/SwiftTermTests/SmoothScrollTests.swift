//
//  SmoothScrollTests.swift
//  SwiftTermTests
//
//  Smooth trackpad scrolling moves the picture by the part of a row the
//  trackpad has banked, while the scroll position stays on whole rows. These
//  tests pin the wheel's half (what becomes an offset, what clears it), the
//  snapshot's overscan row, the hit test, and the renderer's half: a picture
//  moved by a whole row draws exactly what the next scroll position draws, so
//  crossing a row shows no jump.
//

#if os(macOS) && canImport(MetalKit) && DEBUG
import AppKit
import Metal
import Testing
@testable import SwiftTerm

@MainActor
@Suite(.serialized)
struct SmoothScrollTests {
    private static func makePreciseWheelEvent(pixels: Int32) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                               wheel1: pixels, wheel2: 0, wheel3: 0) else {
            return nil
        }
        cg.location = CGPoint(x: 10, y: 10)
        return NSEvent(cgEvent: cg)
    }

    private static func makeLineWheelEvent(lines: Int32) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                               wheel1: lines, wheel2: 0, wheel3: 0) else {
            return nil
        }
        cg.location = CGPoint(x: 10, y: 10)
        return NSEvent(cgEvent: cg)
    }

    /// A view over a hundred lines, scrolled to the bottom.
    private func makeView() -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 260), font: nil,
                                options: TerminalOptions(cols: 64, rows: 12, scrollback: 500))
        view.frameDriver.invalidate()
        var text = ""
        for index in 0..<100 {
            text += "line \(index)\r\n"
        }
        view.feed(text: text)
        return view
    }

    private func yDisp(_ view: TerminalView) -> Int {
        view.withTerminal { $0.displayBuffer.yDisp }
    }

    @Test func offStepsWholeRowsAndKeepsThePictureStill() throws {
        let view = makeView()
        let start = yDisp(view)
        let half = Int32((view.cellDimension.height / 2).rounded(.down))
        let event = try #require(Self.makePreciseWheelEvent(pixels: half))
        view.scrollWheel(with: event)
        #expect(yDisp(view) == start)
        #expect(view.smoothScrollPixelOffset == 0)
    }

    @Test func aPartOfARowMovesThePictureAndAWholeRowMovesThePosition() throws {
        let view = makeView()
        view.smoothScrolling = true
        let start = yDisp(view)
        let cellHeight = view.cellDimension.height
        let half = Int32((cellHeight / 2).rounded(.down))
        let event = try #require(Self.makePreciseWheelEvent(pixels: half))

        view.scrollWheel(with: event)
        #expect(yDisp(view) == start, "the scroll position stays on its row")
        #expect(view.smoothScrollPixelOffset == CGFloat(half))

        view.scrollWheel(with: event)
        view.scrollWheel(with: event)
        let travelled = CGFloat(half * 3)
        let rows = Int(travelled / cellHeight)
        #expect(yDisp(view) == start - rows)
        let wrapped = travelled - CGFloat(rows) * cellHeight
        #expect(abs(view.smoothScrollPixelOffset - wrapped) < 0.001,
                "the offset wraps by the rows the position took")

        // Back down past where it started: the offset turns negative, showing
        // part of the row below, only while there is one.
        let down = try #require(Self.makePreciseWheelEvent(pixels: -half))
        for _ in 0..<4 {
            view.scrollWheel(with: down)
        }
        #expect(yDisp(view) == start, "the bottom holds the position")
        #expect(view.smoothScrollPixelOffset == 0, "there is no row below the bottom to show")
    }

    @Test func theTopShowsNoRowAboveIt() throws {
        let view = makeView()
        view.smoothScrolling = true
        view.scrollTo(row: 0)
        let event = try #require(Self.makePreciseWheelEvent(pixels: 5))
        view.scrollWheel(with: event)
        #expect(yDisp(view) == 0)
        #expect(view.smoothScrollPixelOffset == 0)
    }

    @Test func aWheelNotchAScrollToAndTypingPutThePictureBackOnRows() throws {
        let view = makeView()
        view.smoothScrolling = true
        let up = try #require(Self.makePreciseWheelEvent(pixels: 5))

        view.scrollWheel(with: up)
        #expect(view.smoothScrollPixelOffset == 5)
        let notch = try #require(Self.makeLineWheelEvent(lines: 1))
        let before = yDisp(view)
        view.scrollWheel(with: notch)
        #expect(view.smoothScrollPixelOffset == 0)
        #expect(yDisp(view) == before - 1, "a notch is a whole line")

        view.scrollWheel(with: up)
        #expect(view.smoothScrollPixelOffset == 5)
        view.scrollTo(row: 10)
        #expect(view.smoothScrollPixelOffset == 0)

        view.scrollWheel(with: up)
        #expect(view.smoothScrollPixelOffset == 5)
        view.smoothScrolling = false
        #expect(view.smoothScrollPixelOffset == 0)
    }

    @Test func theSnapshotCarriesTheRowTheOffsetUncovers() {
        let view = makeView()
        view.scrollTo(row: 40)
        let rows = view.withTerminal { $0.rows }
        let snapshot = TerminalSnapshot()

        func refresh() {
            let state = FrameViewState(view: view)
            view.withTerminal { terminal in
                _ = snapshot.refresh(terminal: terminal, viewState: state,
                                     selection: SnapshotSelectionState(selection: nil))
            }
        }

        refresh()
        #expect(snapshot.firstRow == 40)
        #expect(snapshot.rows.count == rows)
        #expect(snapshot.scrollPixelOffset == 0)

        view.smoothScrollPixelOffset = 6
        refresh()
        #expect(snapshot.firstRow == 39, "the row above is drawn above the screen")
        #expect(snapshot.yDisp == 40)
        #expect(snapshot.rows.count == rows + 1)
        #expect(snapshot.scrollPixelOffset == 6)

        view.smoothScrollPixelOffset = -6
        refresh()
        #expect(snapshot.firstRow == 40)
        #expect(snapshot.rows.count == rows + 1, "the row below is drawn under the screen")
        #expect(snapshot.scrollPixelOffset == -6)

        view.smoothScrollPixelOffset = 6
        view.withTerminal { $0.setViewYDisp(0) }
        refresh()
        #expect(snapshot.firstRow == 0)
        #expect(snapshot.rows.count == rows)
        #expect(snapshot.scrollPixelOffset == 0, "no row above the top, so no offset")
    }

    @Test func aPointHitsTheRowDrawnUnderIt() {
        let view = makeView()
        view.scrollTo(row: 40)
        let cellHeight = view.cellDimension.height
        // A third of the way into the first row from the top.
        let point = CGPoint(x: 4, y: view.frame.height - cellHeight / 3)
        #expect(view.calculateMouseHit(at: point).grid.row == 40)

        // The picture moved down by half a row: the point is over the bottom
        // of the row above.
        view.smoothScrollPixelOffset = cellHeight / 2
        #expect(view.calculateMouseHit(at: point).grid.row == 39)
    }

    /// The pixels of the rows' own area, from the top: the view's bottom
    /// margin under the last row shows part of whichever row moves into it.
    private func rowArea(_ frame: MetalRowCacheTests.DrawnFrame,
                         _ harness: MetalRowCacheTests.Harness) -> [UInt8] {
        let width = Int(harness.view.bounds.width * 2)
        let height = Int(CGFloat(harness.screenRows) * harness.view.cellDimension.height * 2)
        return Array(frame.pixels.prefix(width * 4 * height))
    }

    /// Pixels of the pure red the kitty image is, in a BGRA drawable.
    private func redPixels(_ frame: MetalRowCacheTests.DrawnFrame) -> Int {
        stride(from: 0, to: frame.pixels.count - 3, by: 4).reduce(0) { count, index in
            let pixel = frame.pixels
            return pixel[index] < 40 && pixel[index + 1] < 40 && pixel[index + 2] > 200
                ? count + 1 : count
        }
    }

    /// Moving the picture down by a whole row draws what scrolling up a row
    /// draws: the overscan row lands where the top row would be, every row
    /// lands on its slot, so the offset wrapping as the position steps shows
    /// no jump.
    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable))
    func aWholeRowOfOffsetDrawsTheNextPosition() async throws {
        let harness = try #require(MetalRowCacheTests.Harness())
        let view = harness.view
        var text = ""
        for index in 0..<60 {
            text += "\(index) " + MetalRowCacheTests.corpus[index % MetalRowCacheTests.corpus.count]
            text += "\r\n"
        }
        view.feed(text: text)
        let cellHeightPx = view.cellDimension.height * 2
        try #require(cellHeightPx == cellHeightPx.rounded(), "a cell is whole pixels at 2x")

        view.scrollTo(row: 20)
        let above = try #require(await harness.freshFrame())

        view.scrollTo(row: 21)
        view.smoothScrollPixelOffset = view.cellDimension.height
        let moved = try #require(await harness.frame())
        #expect(MetalRowCacheTests.sameBytes(rowArea(moved, harness), rowArea(above, harness)),
                "a whole row of offset draws the row above in place")
        let movedFresh = try #require(await harness.freshFrame())
        #expect(MetalRowCacheTests.sameBytes(
            rowArea(movedFresh, harness), rowArea(above, harness)))

        view.smoothScrollPixelOffset = 0
        let still = try #require(await harness.frame())
        #expect(!MetalRowCacheTests.sameBytes(rowArea(still, harness), rowArea(above, harness)))

        // A selection is drawn on its rows, and moves with them.
        view.selectAll(nil)
        view.smoothScrollPixelOffset = 0
        view.scrollTo(row: 20)
        let selectedAbove = try #require(await harness.freshFrame())
        #expect(!MetalRowCacheTests.sameBytes(rowArea(selectedAbove, harness),
                                               rowArea(above, harness)),
                "the selection is drawn")
        view.scrollTo(row: 21)
        view.smoothScrollPixelOffset = view.cellDimension.height
        let selectedMoved = try #require(await harness.frame())
        #expect(MetalRowCacheTests.sameBytes(rowArea(selectedMoved, harness),
                                              rowArea(selectedAbove, harness)),
                "the selection moves with its rows")
        view.selectNone()

        // A kitty image placed on the rows moves with them too.
        let base = view.withTerminal { $0.displayBuffer.yBase }
        view.smoothScrollPixelOffset = 0
        view.scrollTo(row: base - 3)
        let noImage = try #require(await harness.freshFrame())
        view.feed(text: "\u{1b}[3;4H\u{1b}_Ga=T,f=24,s=1,v=1,t=d,c=6,r=2,i=7;/wAA\u{1b}\\")
        view.scrollTo(row: base - 3)
        let imageAbove = try #require(await harness.freshFrame())
        view.scrollTo(row: base - 2)
        view.smoothScrollPixelOffset = view.cellDimension.height
        let imageMoved = try #require(await harness.frame())
        #expect(redPixels(imageAbove) - redPixels(noImage) > 1_000,
                "the red image is on screen")
        #expect(MetalRowCacheTests.sameBytes(rowArea(imageMoved, harness), rowArea(imageAbove, harness)),
                "the image moves with its rows")

        // And upward: the row below fills the bottom.
        view.scrollTo(row: 22)
        let below = try #require(await harness.freshFrame())
        view.scrollTo(row: 21)
        view.smoothScrollPixelOffset = -view.cellDimension.height
        let movedUp = try #require(await harness.frame())
        #expect(MetalRowCacheTests.sameBytes(rowArea(movedUp, harness), rowArea(below, harness)),
                "a whole row of offset upward draws the row below in place")
    }
}
#endif
