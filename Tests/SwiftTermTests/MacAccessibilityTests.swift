//
//  MacAccessibilityTests.swift
//
//  The macOS view answers as an accessibility text area and serves its
//  selection to the Services menu.
//
#if os(macOS)
import AppKit
import Foundation
import Testing

@testable import SwiftTerm

@MainActor
struct MacAccessibilityTests {
    private func makeView(cols: Int = 20, rows: Int = 4) -> (TerminalView, NSWindow) {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view
        view.resize(cols: cols, rows: rows)
        return (view, window)
    }

    private func select(_ view: TerminalView, from start: Position, to end: Position) {
        view.withTerminal { _ in
            view.selection.setSelection(start: start, end: end)
        }
    }

    @Test func isATextAreaElement() {
        let (view, window) = makeView()
        _ = window
        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .textArea)
        #expect(view.accessibilityLabel() == "Terminal")
    }

    @Test func valueIsTheVisibleScreenOneLinePerRow() {
        let (view, window) = makeView()
        _ = window
        view.feed(text: "hello world\r\nsecond")
        let value = view.accessibilityValue() as? String
        #expect(value == "hello world\nsecond\n\n")
        #expect(view.accessibilityNumberOfCharacters() == (value ?? "").utf16.count)
        #expect(view.accessibilityLine(for: 13) == 1)
        #expect(view.accessibilityRange(forLine: 0) == NSRange(location: 0, length: 12))
        #expect(view.accessibilityString(for: NSRange(location: 12, length: 6)) == "second")
    }

    @Test func selectedTextIsTheSelectionAsCopyGivesIt() {
        let (view, window) = makeView()
        _ = window
        view.feed(text: "hello world\r\nsecond")
        #expect(view.accessibilitySelectedText() == "")

        select(view, from: Position(col: 6, row: 0), to: Position(col: 11, row: 0))
        #expect(view.accessibilitySelectedText() == "world")
        #expect(view.accessibilitySelectedTextRange() == NSRange(location: 6, length: 5))
    }

    @Test func selectionAcrossAWrappedRowHasNoNewline() {
        let (view, window) = makeView(cols: 10, rows: 4)
        _ = window
        view.feed(text: "abcdefghijKLMNO")
        select(view, from: Position(col: 0, row: 0), to: Position(col: 5, row: 1))
        #expect(view.accessibilitySelectedText() == "abcdefghijKLMNO")
        #expect(view.accessibilitySelectedTextRange() == NSRange(location: 0, length: 16))
    }

    @Test func wideCharactersMapToTheirColumns() {
        let (view, window) = makeView()
        _ = window
        view.feed(text: "a\u{4E2D}b")
        #expect(view.accessibilityString(for: view.accessibilityRange(forLine: 0)) == "a\u{4E2D}b\n")
        select(view, from: Position(col: 3, row: 0), to: Position(col: 4, row: 0))
        #expect(view.accessibilitySelectedTextRange() == NSRange(location: 2, length: 1))
    }

    @Test func servicesGetTheSelectionAsAString() {
        let (view, window) = makeView()
        _ = window
        view.feed(text: "hello world")
        #expect(view.validRequestor(forSendType: .string, returnType: nil) as? TerminalView == nil)

        select(view, from: Position(col: 0, row: 0), to: Position(col: 5, row: 0))
        #expect(view.validRequestor(forSendType: .string, returnType: nil) as? TerminalView === view)
        #expect(view.validRequestor(forSendType: .string, returnType: .string) as? TerminalView == nil)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("swiftterm-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(view.writeSelection(to: pasteboard, types: [.string]))
        #expect(pasteboard.string(forType: .string) == "hello")
    }

    @Test func frameOfARangeCoversItsCells() {
        let (view, window) = makeView()
        view.feed(text: "hello world")
        let frame = view.accessibilityFrame(for: NSRange(location: 6, length: 5))
        let local = view.convert(window.convertFromScreen(frame), from: nil)
        let cell = view.cellDimension!
        #expect(abs(local.minX - 6 * cell.width) < 0.5)
        #expect(abs(local.width - 5 * cell.width) < 0.5)
        #expect(abs(local.height - cell.height) < 0.5)
    }
}
#endif
