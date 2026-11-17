const mox = @import("mox");

pub const Item = struct { title: []const u8, url: mox.template.Url };
pub const Home = struct { title: []const u8, items: []const Item };
