const std = @import("std");

// Heuristic estimate (chars/4, min 1 for non-empty). SillyTavern uses
// tiktoken / sentencepiece for exact counts; this is a documented
// approximation for console use until a BPE tokenizer is ported.
pub fn estimateTokens(text: []const u8) usize {
    if (text.len == 0) return 0;
    return (text.len + 3) / 4;
}

test "estimateTokens" {
    try std.testing.expectEqual(@as(usize, 0), estimateTokens(""));
    try std.testing.expectEqual(@as(usize, 1), estimateTokens("abcd"));
    try std.testing.expectEqual(@as(usize, 2), estimateTokens("abcdefgh"));
    try std.testing.expectEqual(@as(usize, 1), estimateTokens("a"));
}
