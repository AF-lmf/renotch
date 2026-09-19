import Foundation

/// Line access to an append-only JSONL file without loading it.
///
/// Lines longer than `maxLineLength` are skipped without being buffered. A
/// final segment with no trailing newline (a line Codex is still writing) is
/// never visited and never counted as scanned.
struct CodexLogLineScanner {
    var chunkSize = 64 * 1024
    var maxLineLength = CodexRateLimitLineParser.maxLineLength

    struct BackwardResult: Equatable {
        /// Bytes read from disk.
        var bytesRead: Int
        /// Offset where every line at or after it (up to `end`) has been visited
        /// or skipped as too long. Resume a later backward scan from here.
        var resumeOffset: UInt64
        /// Offset just past the last complete line in the scanned range.
        var completeEnd: UInt64
    }

    /// Visits complete lines ending at or before `end`, newest first. `visit`
    /// returns false to stop; the stopping line counts as visited.
    func scanBackward(url: URL, end: UInt64, byteBudget: Int,
                      visit: (UnsafeRawBufferPointer) -> Bool) -> BackwardResult {
        var result = BackwardResult(bytesRead: 0, resumeOffset: end, completeEnd: end)
        guard end > 0, byteBudget > 0, let handle = try? FileHandle(forReadingFrom: url) else { return result }
        defer { try? handle.close() }

        var position = end
        var carry = [UInt8]()
        var carryOverflow = false
        var seenNewline = false
        var stopped = false

        while position > 0, result.bytesRead < byteBudget, !stopped {
            let length = Int(min(UInt64(chunkSize), position, UInt64(byteBudget - result.bytesRead)))
            let chunkStart = position - UInt64(length)
            guard (try? handle.seek(toOffset: chunkStart)) != nil,
                  let data = try? handle.read(upToCount: length), data.count == length else { break }
            position = chunkStart
            result.bytesRead += length

            data.withUnsafeBytes { (chunk: UnsafeRawBufferPointer) in
                var lineEnd = chunk.count
                var index = chunk.count - 1
                while index >= 0 {
                    if chunk[index] == 0x0A {
                        let lineStart = chunkStart + UInt64(index + 1)
                        if !seenNewline {
                            // Everything after the last newline is an unfinished write.
                            seenNewline = true
                            result.completeEnd = lineStart
                        } else if !carryOverflow, (lineEnd - index - 1) + carry.count <= maxLineLength {
                            let segment = UnsafeRawBufferPointer(rebasing: chunk[(index + 1)..<lineEnd])
                            let keepGoing: Bool
                            if carry.isEmpty {
                                keepGoing = segment.isEmpty || visit(segment)
                            } else {
                                var line = [UInt8](segment)
                                line.append(contentsOf: carry)
                                keepGoing = line.withUnsafeBytes { visit($0) }
                            }
                            if !keepGoing { result.resumeOffset = lineStart; stopped = true; return }
                        }
                        result.resumeOffset = lineStart
                        carry.removeAll(keepingCapacity: true)
                        carryOverflow = false
                        lineEnd = index
                    }
                    index -= 1
                }
                if !carryOverflow {
                    if carry.count + lineEnd > maxLineLength {
                        carryOverflow = true
                        carry.removeAll(keepingCapacity: true)
                    } else {
                        carry.insert(contentsOf: UnsafeRawBufferPointer(rebasing: chunk[0..<lineEnd]), at: 0)
                    }
                }
            }
        }
        if !stopped, position == 0 {
            if seenNewline {
                // The file's first line has no newline before it.
                if !carryOverflow, !carry.isEmpty { _ = carry.withUnsafeBytes { visit($0) } }
            } else {
                result.completeEnd = 0 // one unfinished line and nothing else
            }
            result.resumeOffset = 0
        } else if !stopped, result.resumeOffset >= end {
            // The whole budget went into one line longer than the budget; skip
            // past it so the next scan makes progress (it is too long to matter).
            result.resumeOffset = position
        }
        return result
    }

    struct ForwardResult: Equatable {
        var bytesRead: Int
        /// Offset just past the last complete line; the next forward scan starts here.
        var completeEnd: UInt64
    }

    /// Visits complete lines in `start..<end`, oldest first. `start` must be a
    /// line boundary. Stops early (without advancing past unread lines) when
    /// `byteBudget` runs out.
    func scanForward(url: URL, from start: UInt64, to end: UInt64, byteBudget: Int,
                     visit: (UnsafeRawBufferPointer) -> Void) -> ForwardResult {
        var result = ForwardResult(bytesRead: 0, completeEnd: start)
        guard end > start, byteBudget > 0, let handle = try? FileHandle(forReadingFrom: url) else { return result }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: start)) != nil else { return result }

        var position = start
        var carry = [UInt8]()
        var carryOverflow = false
        while position < end, result.bytesRead < byteBudget {
            let length = Int(min(UInt64(chunkSize), end - position, UInt64(byteBudget - result.bytesRead)))
            guard let data = try? handle.read(upToCount: length), data.count == length else { break }
            let chunkStart = position
            position += UInt64(length)
            result.bytesRead += length
            data.withUnsafeBytes { (chunk: UnsafeRawBufferPointer) in
                var lineStart = 0
                for index in 0..<chunk.count where chunk[index] == 0x0A {
                    if !carryOverflow, carry.count + (index - lineStart) <= maxLineLength {
                        if carry.isEmpty {
                            visit(UnsafeRawBufferPointer(rebasing: chunk[lineStart..<index]))
                        } else {
                            carry.append(contentsOf: UnsafeRawBufferPointer(rebasing: chunk[lineStart..<index]))
                            carry.withUnsafeBytes { visit($0) }
                        }
                    }
                    carry.removeAll(keepingCapacity: true)
                    carryOverflow = false
                    lineStart = index + 1
                    result.completeEnd = chunkStart + UInt64(index + 1)
                }
                if !carryOverflow {
                    if carry.count + (chunk.count - lineStart) > maxLineLength {
                        carryOverflow = true
                        carry.removeAll(keepingCapacity: true)
                    } else {
                        carry.append(contentsOf: UnsafeRawBufferPointer(rebasing: chunk[lineStart..<chunk.count]))
                    }
                }
            }
        }
        return result
    }
}
