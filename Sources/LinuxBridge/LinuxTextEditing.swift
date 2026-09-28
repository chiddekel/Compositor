import Foundation

/// Native editors report UTF-16 positions, matching the shared text color runs.
enum LinuxTextEditing {
    static func validRange(location: Int, length: Int, in text: String) -> Bool {
        let units = Array(text.utf16)
        guard location >= 0, length >= 0, location <= units.count, length <= units.count - location else { return false }
        func boundary(_ index: Int) -> Bool {
            index == 0 || index == units.count || !(0xDC00...0xDFFF).contains(units[index])
        }
        return boundary(location) && boundary(location + length)
    }

    static func replace(in draft: inout TextDraft, location: Int, length: Int, with replacement: String) -> Bool {
        guard validRange(location: location, length: length, in: draft.style.content),
              replacement.utf16.count <= 100_000 - (draft.style.content.utf16.count - length) else { return false }
        var style = draft.style
        let range = NSRange(location: location, length: length)
        style.replaceCharacters(in: range, withLength: replacement.utf16.count)
        style.content = (style.content as NSString).replacingCharacters(in: range, with: replacement)
        guard style.isValid else { return false }
        draft.style = style
        draft.selection = NSRange(location: location + replacement.utf16.count, length: 0)
        return true
    }

    /// Compatibility for callers sending whole strings. Native edit events should
    /// use their exact range, since repeated letters make a string diff ambiguous.
    static func setContent(_ content: String, in draft: inout TextDraft) -> Bool {
        if content == draft.style.content { return true }
        let old = Array(draft.style.content.utf16), new = Array(content.utf16)
        guard new.count <= 100_000 else { return false }
        var start = 0
        while start < min(old.count, new.count), old[start] == new[start] { start += 1 }
        if start < old.count, (0xDC00...0xDFFF).contains(old[start]) { start -= 1 }
        var end = old.count, newEnd = new.count
        while end > start, newEnd > start, old[end - 1] == new[newEnd - 1] { end -= 1; newEnd -= 1 }
        if end < old.count, (0xDC00...0xDFFF).contains(old[end]) { end += 1; newEnd += 1 }
        let replacement = String(decoding: new[start..<newEnd], as: UTF16.self)
        return replace(in: &draft, location: start, length: end - start, with: replacement)
    }
}
