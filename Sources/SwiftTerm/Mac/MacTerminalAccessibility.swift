//
//  MacTerminalAccessibility.swift
//
//  The macOS terminal view as an accessibility text area and a Services
//  requestor, so that VoiceOver, the system text services, the Services menu
//  and launchers that read the front app's selection through the
//  Accessibility API see the terminal's selection and its screen.
//
//  Everything is computed when a client asks, never per frame: the visible
//  screen is read under the terminal lock into a plain-text model, used for
//  that one answer and dropped.
//

#if !SWIFTTERM_EMBEDDED
#if os(macOS)
import AppKit
import Foundation

/// The visible screen as plain text, with the map from a row's columns to the
/// text's UTF-16 offsets that accessibility ranges use. Rows end with a
/// newline, except a row the next one continues (a soft wrap): those are
/// joined, as a copy of a selection over them joins them, so the selected
/// text and its range in the value agree.
struct AccessibleScreenText {
    /// The rows, a newline after every row but the last and a wrapped one.
    let text: NSString
    /// The UTF-16 offset of each row's first character in `text`.
    let lineStarts: [Int]
    /// The UTF-16 length of each row's text, without its newline.
    let lineLengths: [Int]
    /// For each row, the offset within the row at which each column starts,
    /// with one more entry for the column past the last: a wide character's
    /// second column maps to the character's start, and a column past the
    /// row's text maps to the row's end.
    let columnOffsets: [[Int]]

    var length: Int { text.length }
    var rowCount: Int { lineStarts.count }

    /// Builds the model from the rows the display buffer shows.
    /// The terminal lock must be held.
    static func make(terminal: Terminal) -> AccessibleScreenText {
        let buffer = terminal.displayBuffer
        let cols = terminal.cols
        let top = buffer.yDisp
        // The cursor's row keeps its blank cells up to the cursor, so the
        // insertion point lands on its column, not after the row's text.
        let cursorRow = buffer.yBase + buffer.y - top
        let cursorCol = min(buffer.x, cols)
        var text = ""
        var lineStarts: [Int] = []
        var lineLengths: [Int] = []
        var columnOffsets: [[Int]] = []
        var offset = 0
        for row in 0..<terminal.rows {
            let lineIndex = top + row
            let isLine = lineIndex >= 0 && lineIndex < buffer.lines.count
            if row > 0, !(isLine && buffer.lines[lineIndex].isWrapped) {
                text += "\n"
                offset += 1
            }
            lineStarts.append(offset)
            var offsets = [Int](repeating: 0, count: cols + 1)
            var rowText = ""
            var rowLength = 0
            var col = 0
            if isLine {
                let line = buffer.lines[lineIndex]
                // A row the next one continues keeps its trailing blanks:
                // they are part of the wrapped line's text.
                let nextIndex = lineIndex + 1
                let wraps = row + 1 < terminal.rows && nextIndex < buffer.lines.count
                    && buffer.lines[nextIndex].isWrapped
                var limit = wraps ? line.count : line.getTrimmedLength()
                if row == cursorRow { limit = max(limit, cursorCol) }
                limit = min(limit, line.count, cols)
                while col < limit {
                    let cell = line.packedView(at: col)
                    let width = max(1, Int(cell.width))
                    let cellText = cell.code == 0 ? " " : cell.getText()
                    for covered in col..<min(col + width, cols) {
                        offsets[covered] = rowLength
                    }
                    rowText += cellText
                    rowLength += cellText.utf16.count
                    col += width
                }
            }
            for rest in min(col, cols)...cols {
                offsets[rest] = rowLength
            }
            text += rowText
            offset += rowLength
            lineLengths.append(rowLength)
            columnOffsets.append(offsets)
        }
        return AccessibleScreenText(
            text: text as NSString, lineStarts: lineStarts,
            lineLengths: lineLengths, columnOffsets: columnOffsets)
    }

    /// The text offset of a buffer position, clamped to the screen: a
    /// position above the screen is its start, one below is its end.
    func offset(of position: Position, top: Int) -> Int {
        guard rowCount > 0 else { return 0 }
        let row = position.row - top
        if row < 0 { return 0 }
        if row >= rowCount { return length }
        let offsets = columnOffsets[row]
        let col = max(0, min(position.col, offsets.count - 1))
        return lineStarts[row] + offsets[col]
    }

    /// The row an offset falls on; the newline after a row belongs to it.
    func row(of index: Int) -> Int {
        guard rowCount > 0 else { return 0 }
        var low = 0
        var high = rowCount - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= index {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    /// The first column on a row whose text starts at or after an offset
    /// within that row: the column of a range's first character, or the
    /// column just past a range's end.
    func column(of index: Int, row: Int) -> Int {
        let within = index - lineStarts[row]
        let offsets = columnOffsets[row]
        return offsets.firstIndex { $0 >= within } ?? (offsets.count - 1)
    }

    /// The range of one row, its newline included.
    func range(ofLine row: Int) -> NSRange {
        guard row >= 0, row < rowCount else { return NSRange(location: NSNotFound, length: 0) }
        let end = row + 1 < rowCount ? lineStarts[row + 1] : length
        return NSRange(location: lineStarts[row], length: end - lineStarts[row])
    }

    /// The range clamped to the text.
    func clamp(_ range: NSRange) -> NSRange {
        // Computed without adding location and length: a client may pass
        // NSNotFound with a length, whose sum overflows.
        let location = max(0, min(range.location, length))
        return NSRange(location: location, length: max(0, min(range.length, length - location)))
    }
}

extension TerminalView {
    /// The visible screen's text model, read under the terminal lock.
    func accessibleScreenText() -> (screen: AccessibleScreenText, top: Int) {
        withTerminal { terminal in
            (AccessibleScreenText.make(terminal: terminal), terminal.displayBuffer.yDisp)
        }
    }

    /// The selected text as plain text, wrapped rows joined as a copy joins
    /// them, or nil when nothing is selected: what accessibility clients and
    /// the Services menu get. A host whose program draws a selection of its
    /// own, one the view does not hold, overrides this to answer with it.
    @objc open func accessibleSelectedText() -> String? {
        withTerminal { _ in
            guard let selection, selection.active else { return nil }
            let text = selection.getSelectedText()
            return text.isEmpty ? nil : text
        }
    }

    open override func isAccessibilityElement() -> Bool {
        true
    }

    open override func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    open override func accessibilityLabel() -> String? {
        super.accessibilityLabel() ?? "Terminal"
    }

    open override func isAccessibilityFocused() -> Bool {
        window?.firstResponder === self
    }

    open override func accessibilityValue() -> Any? {
        accessibleScreenText().screen.text as String
    }

    open override func accessibilityNumberOfCharacters() -> Int {
        accessibleScreenText().screen.length
    }

    open override func accessibilitySelectedText() -> String? {
        accessibleSelectedText() ?? ""
    }

    open override func accessibilitySelectedTextRange() -> NSRange {
        let (screen, top) = accessibleScreenText()
        let selected: (Position, Position)? = withTerminal { _ in
            guard let selection, selection.active else { return nil }
            return Position.compare(selection.start, selection.end) == .after
                ? (selection.end, selection.start) : (selection.start, selection.end)
        }
        if let (start, end) = selected {
            let from = screen.offset(of: start, top: top)
            let to = screen.offset(of: end, top: top)
            return NSRange(location: from, length: max(0, to - from))
        }
        let cursor = withTerminal { terminal in
            Position(col: terminal.buffer.x, row: terminal.buffer.y + terminal.buffer.yBase)
        }
        return NSRange(location: screen.offset(of: cursor, top: top), length: 0)
    }

    open override func accessibilitySelectedTextRanges() -> [NSValue]? {
        [NSValue(range: accessibilitySelectedTextRange())]
    }

    open override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: accessibleScreenText().screen.length)
    }

    open override func accessibilityInsertionPointLineNumber() -> Int {
        let (screen, _) = accessibleScreenText()
        return screen.row(of: accessibilitySelectedTextRange().location)
    }

    open override func accessibilityLine(for index: Int) -> Int {
        let screen = accessibleScreenText().screen
        guard index >= 0, index <= screen.length else { return NSNotFound }
        return screen.row(of: index)
    }

    open override func accessibilityRange(forLine line: Int) -> NSRange {
        accessibleScreenText().screen.range(ofLine: line)
    }

    open override func accessibilityString(for range: NSRange) -> String? {
        let screen = accessibleScreenText().screen
        return screen.text.substring(with: screen.clamp(range))
    }

    open override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let string = accessibilityString(for: range) else { return nil }
        return NSAttributedString(string: string, attributes: [.font: fontSet.normal])
    }

    open override func accessibilityRange(for index: Int) -> NSRange {
        let screen = accessibleScreenText().screen
        guard index >= 0, index < screen.length else { return NSRange(location: NSNotFound, length: 0) }
        return screen.text.rangeOfComposedCharacterSequence(at: index)
    }

    open override func accessibilityStyleRange(for index: Int) -> NSRange {
        // The plain-text model has one style: the whole screen.
        NSRange(location: 0, length: accessibleScreenText().screen.length)
    }

    open override func accessibilityRange(for point: NSPoint) -> NSRange {
        guard let window, let cellDimension, cellDimension.width > 0, cellDimension.height > 0 else {
            return NSRange(location: NSNotFound, length: 0)
        }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        let screen = accessibleScreenText().screen
        guard screen.rowCount > 0 else { return NSRange(location: NSNotFound, length: 0) }
        let row = max(0, min(screen.rowCount - 1, Int((bounds.height - local.y) / cellDimension.height)))
        let offsets = screen.columnOffsets[row]
        let col = max(0, min(offsets.count - 1, Int(local.x / cellDimension.width)))
        let index = screen.lineStarts[row] + offsets[col]
        if offsets[col] >= screen.lineLengths[row] {
            return NSRange(location: index, length: 0)
        }
        return screen.text.rangeOfComposedCharacterSequence(at: index)
    }

    open override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let window, let cellDimension else { return .zero }
        let screen = accessibleScreenText().screen
        guard screen.rowCount > 0 else { return .zero }
        let clamped = screen.clamp(range)
        let end = clamped.location + clamped.length
        let firstRow = screen.row(of: clamped.location)
        let lastRow = screen.row(of: clamped.length > 0 ? end - 1 : end)
        let rect: NSRect
        if firstRow == lastRow {
            let firstCol = screen.column(of: clamped.location, row: firstRow)
            let endCol = max(firstCol, screen.column(of: end, row: firstRow))
            rect = NSRect(
                x: CGFloat(firstCol) * cellDimension.width,
                y: bounds.height - CGFloat(firstRow + 1) * cellDimension.height,
                width: CGFloat(endCol - firstCol) * cellDimension.width,
                height: cellDimension.height)
        } else {
            // Several rows: the full width of every row the range touches.
            let cols = screen.columnOffsets[firstRow].count - 1
            rect = NSRect(
                x: 0,
                y: bounds.height - CGFloat(lastRow + 1) * cellDimension.height,
                width: CGFloat(cols) * cellDimension.width,
                height: CGFloat(lastRow - firstRow + 1) * cellDimension.height)
        }
        return window.convertToScreen(convert(rect, to: nil))
    }

    /// Posts one value-changed notification for the output of the next half
    /// second, however many frames it draws, so that a busy terminal does not
    /// flood accessibility clients with a notification per frame.
    func scheduleAccessibilityValueChanged() {
        guard !accessibilityValueChangePending else { return }
        accessibilityValueChangePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.accessibilityValueChangePending = false
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    // MARK: Services

    /// Registers the plain-string send type once per process, so that AppKit
    /// asks a terminal view whether it can serve the Services menu.
    static let registerServicesTypes: Void = {
        NSApplication.shared.registerServicesMenuSendTypes([.string], returnTypes: [])
    }()

    open override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if returnType == nil, sendType == .string, accessibleSelectedText() != nil {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
}

extension TerminalView: @MainActor NSServicesMenuRequestor {
    public func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard types.contains(.string), let text = accessibleSelectedText() else { return false }
        pboard.clearContents()
        return pboard.setString(text, forType: .string)
    }

    public func readSelection(from pboard: NSPasteboard) -> Bool {
        // The terminal takes no text back from a service.
        false
    }
}

#endif
#endif // !SWIFTTERM_EMBEDDED
