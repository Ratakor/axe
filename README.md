# Axe 🪓

A fully customizable, drop-in replacement for `std.Options.LogFn` with support
for multiple file logging, buffering, JSON, time, custom format, colors
(automatic tty detection, windows support, NO_COLOR support, CLICOLOR_FORCE
support), and thread safety (multiple mutex interface available)!

![](screenshot.png)

## Usage

Add it to an existing project with this command:
```sh
zig fetch --save git+https://github.com/Ratakor/axe
```
Then add the module your build.zig.
```zig
const axe = b.dependency("axe", .{}).module("axe");
exe.root_module.addImport("axe", axe);
```

Check [example.zig](example/example.zig) for how to use it!

## Log with location
Since zig doesn't have macro it's hard to implement logging with source
location because we have to pass @src() around.
But it's possible to make helper for it.

Here is a sample one:
```zig
const std = @import("std");
const Axe = @import("axe").Axe(.{});

fn logInfoSrc(
    logger: anytype,
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    const source = std.fmt.comptimePrint("{s}:{s}:{d}:{d}: ", .{
        src.file,
        src.fn_name,
        src.line,
        src.column,
    });
    logger.info(source ++ format, args);
}

pub fn main() !void {
    try Axe.init(std.heap.page_allocator, &.{}, null);
    defer Axe.deinit(std.heap.page_allocator);

    // info: example.zig:main:24:21: Hello, World
    logInfoSrc(Axe, @src(), "Hello, World!", .{});
}
```

## TODO
- Replace stdout/stderr with files? (see [0c55fd3](https://github.com/Ratakor/axe/commit/0c55fd3e2f336d2fc801e759fcd5f910cba66792))
- Actually have a good interface for @src (impossible)
- Add a way to combine multiple loggers into one.
