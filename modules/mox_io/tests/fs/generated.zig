//! Build-generated embedded images match the source asset tree.

const testing = @import("std").testing;
const mox_io = @import("mox_io");
const assets = @import("test-assets");

test "embed build helper generates an importable resource module" {
    const fs = try mox_io.fs.EmbeddedFs.init(assets.image);
    try testing.expectEqualStrings("<h1>mox-io</h1>\n", try fs.readFile("index.html"));
    try testing.expectEqualStrings("embedded assets\n", try fs.readFile("nested/message.txt"));
    try testing.expectEqual(@as(usize, 2), fs.stats().files);
    try testing.expectEqual(@as(usize, 2), fs.stats().directories);
}
