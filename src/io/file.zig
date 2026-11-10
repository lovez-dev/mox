//! 文件读取：在 `Work` 池线程里阻塞读，完成回调回到循环线程。
//!
//! 文件没有可移植的原生异步接口，因此这是通用兜底。读操作只持有 `Io` 的值
//! 拷贝（`{ userdata, vtable }` 是平凡的），从而能安全地在池线程里调用
//! `io.vtable.readFileInto`，不必触碰只属于循环线程的 `*Loop`。

const root = @import("io.zig");

const Io = root.Io;
const Work = root.Work;

pub const ReadFile = struct {
    work: Work,
    io: Io,
    path: []const u8,
    buf: []u8,
    len: usize = 0,
    err: ?anyerror = null,

    pub fn init(io: Io, path: []const u8, buf: []u8) ReadFile {
        return .{ .work = Work.init(run), .io = io, .path = path, .buf = buf };
    }

    fn run(w: *Work) void {
        const self: *ReadFile = @fieldParentPtr("work", w);
        self.len = self.io.vtable.readFileInto(self.io.userdata, self.path, self.buf) catch |e| {
            self.err = e;
            return;
        };
    }

    pub fn getResult(self: *const ReadFile) ![]const u8 {
        if (self.err) |e| return e;
        return self.buf[0..self.len];
    }
};
