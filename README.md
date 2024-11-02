# Axe 🪓

A fully customizable, drop-in replacement for `std.Options.LogFn` with support
for multiple file logging, buffering, colors (NO_COLOR supported), JSON, time
and thread safety (multiple mutex interface available)!

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

// info: example.zig:main:84:36: Hello, World!
logInfoSrc(axe.Comptime(.{}), @src(), "Hello, World!", .{});
```

## TODO
- support a different config for each writers?
- actually have a good interface for @src (impossible)
- truncate lines with more than 80-100 columns
- support windows colors on comptime interface for stdout/stderr
