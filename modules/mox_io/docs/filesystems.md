# Memory and embedded filesystems

`mox_io.fs.MemoryFs` stores writable files. `mox_io.fs.EmbeddedFs` reads an immutable image that must remain valid while in use. Both expose file metadata, directory iteration and `stats()`. Their operations complete immediately and do not submit work to a Loop.

## Embed a directory

After adding the `mox_io` dependency, attach a resource module in your application's `build.zig`:

```zig
const dependency = b.dependency("mox_io", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("mox_io", dependency.module("mox_io"));
exe.root_module.addImport("assets", @import("mox_io").embed(b, .{
    .directory = b.path("assets"),
}));
```

Read the embedded files in application code:

```zig
const mox_io = @import("mox_io");
const assets = @import("assets");

const fs = try mox_io.fs.EmbeddedFs.init(assets.image);
const html = try fs.readFile("index.html");
```

No separate install or command is required. The helper builds `mox-io-embed` for the host, generates the module in Zig's cache, and attaches its dependencies. It tracks nested file contents and directory membership, including additions, deletions and empty directories. Unchanged inputs reuse cached output.

The directory may also be a dependency path or an immutable generated directory, such as `files.getDirectory()` from `b.addWriteFiles()`. The producing step must declare its own inputs. Source directories use `b.path(...)` or `b.graph.cwdRelativePath(...)`; raw cache and install paths are not accepted.

All files, including hidden files, are included. Symbolic links and special files are rejected. Use a dedicated resource directory. Input files must remain stable while packing. Defaults limit the complete image to 4 GiB and the index to 1,000,000 entries; set `max_bytes` and `max_entries` in the helper options to change them.

A complete downstream example is in [examples/embed](../examples/embed/build.zig). Run `zig build run` in that directory; cross builds use the same helper.

## Standalone command

```sh
zig build embed -- ./assets -o ./assets.lzfs
zig build embed -- ./assets --module ./generated/assets
zig build install
zig-out/bin/mox-io-embed ./assets -o ./assets.lzfs
```

Windows installs `mox-io-embed.exe`. Output must be outside the input directory. `--module` writes `root.zig` and `assets.lzfs`. The command accepts `--max-bytes`, `--max-entries` and `--help`; output files are replaced atomically after successful writes. Build scripts can also obtain the executable through `dependency.artifact("mox-io-embed")`.

## Writable memory files

```zig
var fs: mox_io.fs.MemoryFs = undefined;
try fs.init(allocator, .{ .nodes = 256, .open_files = 128 });
defer fs.deinit() catch @panic("open files remain");

try fs.makePath("cache/pages");
try fs.writeFile("cache/pages/index.html", "Hello");

const file = try fs.open("cache/pages/index.html", .{ .access = .read_write });
defer file.close() catch @panic("invalid file handle");
try file.reserve(4096);
_ = try file.writeAt("!", 5);

var buffer: [64]u8 = undefined;
const contents = try fs.readFile("cache/pages/index.html", &buffer);
const snapshot = fs.stats();
```

Pass any `mox_io.mem.Allocator`, including a shared tracking allocator also used by Loops. Keep `MemoryFs` at a stable address and serialize its access. A shared allocator does not make the filesystem concurrent.

Metadata occupies one allocation. `nodes` includes the root, directories and unlinked files still held open; `open_files` bounds simultaneous handles. Paths are indexed in sorted order. Lookup is O(log n), handle access is O(1), and inserting or removing an entry is O(n). File buffers grow geometrically; `reserve()` avoids growth during subsequent writes within capacity. Reads and opens of existing files allocate nothing.

`stats().memory` reports allocation calls, failures, requested and reserved bytes, and peaks. `data_bytes` counts logical file data; `capacity_bytes` counts reserved file buffers. Both include unlinked files until their last handle closes. Embedded image bytes are reported separately by `EmbeddedFs.stats().image_bytes` and require no runtime allocation.

## Semantics

| Operation | MemoryFs | EmbeddedFs |
| --- | --- | --- |
| `readFile(path, buffer)` / `readFile(path)` | Copies the whole file; small buffers return `BufferTooSmall` | Returns a `[]const u8` into the image; keep the image valid |
| `open(path, options)` | Uses `fs.OpenOptions`; returns a checked handle | Accepts only read access with `open_existing` |
| File reads | `read`, `readAt`, `seek` | `read`, `readAt`, `seek` |
| File writes | `write`, `writeAt`, `truncate`, `reserve` | Read-only |
| Directories | `makeDir`, `makePath`, `removeDir`, `iterate` | `iterate` |
| Lifetime | Close files before `deinit`; otherwise it returns `Busy` | Keep the image immutable and alive; no close/deinit is needed |

- Paths are case-sensitive UTF-8 with `/` separators. One leading `/` is optional; `""` and `"/"` name the root. Dot components, empty components, trailing slashes, backslashes, colons and NUL are rejected. Maximum path length is 4096 bytes.
- Memory file copies share one handle and cursor. Closing any copy invalidates all copies; generations never wrap. Deleting a file removes its name immediately, while open handles retain its data. A new file with the same name is independent.
- `writeFile` preserves existing contents on allocation failure. Writes beyond EOF and growing truncations fill gaps with zeroes. Shrinking retains capacity. `max_file_size` and `max_data_bytes` limit logical size, including unlinked data; allocator overhead is separate.
- Directory iteration returns direct children in bytewise name order. Memory iterators report `StaleIterator` after directory mutations; returned names must not outlive those mutations. Recursive `makePath` may leave successfully created parents after an error.
- Memory permissions are metadata, while open access flags control handle reads and writes. Timestamps are zero. Embedded permissions are unspecified. There is no OS mount, writable overlay, rename operation or transparent conversion to native Loop handles.
- Immutable embedded views may be shared by threads. Each `EmbeddedFs.File` cursor needs its own owner. Mount validates structure and bounds; it does not authenticate payloads or permit later mutation of the image.

## Image format

Version 1 stores a 40-byte header, sorted 40-byte index entries, concatenated UTF-8 paths, and concatenated file contents. Integers are little-endian; no pointers, native padding, timestamps or host paths are stored. Empty directories have explicit entries; the root is implicit. File data is uncompressed and can be read without copying.

| Header offset | Field |
| --- | --- |
| 0 | Eight-byte magic `LZIOFS\r\n` |
| 8 | Version, u32 |
| 12 | Index entry size, u32 |
| 16 | Entry count, u64 |
| 24 | Path section size, u64 |
| 32 | Data section size, u64 |

| Entry offset | Field |
| --- | --- |
| 0 | Offset into path section, u64 |
| 8 | Path length, u32 |
| 12 | Kind: 0 = file, 1 = directory, u32 |
| 16 | Offset into data section, u64 |
| 24 | Data length, u64 |
| 32 | Earlier parent directory index, u64; all ones means root |

Mounting checks exact section sizes, contiguous ranges, canonical paths, strict ordering, uniqueness and parent relationships. It scans metadata once without allocation; file lookup uses binary search. Packing retains metadata and streams file bytes through a fixed buffer, so it does not hold all payloads in memory.
