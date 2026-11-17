//! Read build-embedded assets through the immutable filesystem API.

const std = @import("std");
const mox_io = @import("mox_io");
const assets = @import("assets");

pub fn main(init: std.process.Init) !void {
    const fs = try mox_io.fs.EmbeddedFs.init(assets.image);
    var buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    try output.interface.writeAll(try fs.readFile("nested/message.txt"));
    try output.interface.print("files={d} directories={d}\n", .{ fs.stats().files, fs.stats().directories });
    try output.interface.flush();
}
