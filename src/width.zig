//! Lebar tampilan karakter di terminal (pengganti crate unicode-width).
//! Aturan: 0 untuk penanda gabungan/zero-width, 2 untuk CJK/emoji lebar, 1 untuk sisanya.

const std = @import("std");

pub fn charWidth(cp: u21) u8 {
    // Zero width: combining marks, format characters, variation selectors.
    if (cp == 0x200B or cp == 0x200C or cp == 0x200D or cp == 0xFEFF) return 0;
    if (cp >= 0x0300 and cp <= 0x036F) return 0;
    if (cp >= 0x1AB0 and cp <= 0x1AFF) return 0;
    if (cp >= 0x1DC0 and cp <= 0x1DFF) return 0;
    if (cp >= 0x20D0 and cp <= 0x20FF) return 0;
    if (cp >= 0xFE00 and cp <= 0xFE0F) return 0;
    if (cp >= 0xFE20 and cp <= 0xFE2F) return 0;
    if (cp >= 0xE0100 and cp <= 0xE01EF) return 0;

    // Wide: CJK, Hangul, kana, fullwidth forms, dan emoji.
    if (cp >= 0x1100 and cp <= 0x115F) return 2;
    if (cp >= 0x2E80 and cp <= 0x303E) return 2;
    if (cp >= 0x3041 and cp <= 0x33FF) return 2;
    if (cp >= 0x3400 and cp <= 0x4DBF) return 2;
    if (cp >= 0x4E00 and cp <= 0x9FFF) return 2;
    if (cp >= 0xA000 and cp <= 0xA4CF) return 2;
    if (cp >= 0xA960 and cp <= 0xA97F) return 2;
    if (cp >= 0xAC00 and cp <= 0xD7A3) return 2;
    if (cp >= 0xF900 and cp <= 0xFAFF) return 2;
    if (cp >= 0xFE30 and cp <= 0xFE4F) return 2;
    if (cp >= 0xFF00 and cp <= 0xFF60) return 2;
    if (cp >= 0xFFE0 and cp <= 0xFFE6) return 2;
    if (cp >= 0x1F300 and cp <= 0x1F64F) return 2;
    if (cp >= 0x1F900 and cp <= 0x1F9FF) return 2;
    if (cp >= 0x1F680 and cp <= 0x1F6FF) return 2;
    if (cp >= 0x1FA70 and cp <= 0x1FAFF) return 2;
    if (cp >= 0x20000 and cp <= 0x3FFFD) return 2;
    return 1;
}

/// Lebar UTF-8 string; byte yang tidak valid dihitung 1.
pub fn strWidth(s: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            total += 1;
            i += 1;
            continue;
        };
        if (i + n > s.len) {
            total += 1;
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + n]) catch {
            total += 1;
            i += 1;
            continue;
        };
        total += charWidth(cp);
        i += n;
    }
    return total;
}

test "widths" {
    try std.testing.expectEqual(@as(u8, 1), charWidth('a'));
    try std.testing.expectEqual(@as(u8, 2), charWidth(0x4F60));
    try std.testing.expectEqual(@as(usize, 4), strWidth("a你b"));
}
