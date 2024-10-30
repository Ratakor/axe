const clog = @import("clog");
const std = @import("std");

pub const std_options: std.Options = .{
    .logFn = clog.Comptime(.{}).standardLog,
};

pub fn main() !void {
    // comptime
    const comptime_log = clog.Comptime(.{
        .styles = .none, // colored by default
        .level_text = .{ // same as zig by default
            .err = "ErrOr",
            .debug = "DeBuG",
        },
        // .scope = .main, // scope can also be set here, it will be ignored for std.log
        .writers = &.{ std.io.getStdOut().writer().any() }, // stderr is default
        .buffering = true, // true by default
        .time = .disabled, // disabled by default, doesn't work at comptime
    });
    comptime_log.debug("Hello, comptime with no colors", .{});
    comptime_log.scoped(.main).err("comptime scoped", .{});

    // comptime with std.log
    std.log.info("std.log.info with clog.Comptime(.{{}})", .{});
    std.log.scoped(.main).warn("this is scoped", .{});

    // runtime
    var f = try std.fs.cwd().createFile("log.txt", .{});
    defer f.close();
    const writers = [_]std.io.AnyWriter{
        std.io.getStdErr().writer().any(),
        f.writer().any(),
    };
    const log = try clog.Runtime(.{
        .styles = .{
            .err = &.{ .{ .bg_hex = "ff0000" }, .bold, .underline, },
            .warn = &.{ .{ .rgb = .{ .r = 255, .g = 255, .b = 0 } }, .strikethrough, },
            .info = &.{ .green, .italic, },
        },
        .level_text = .{
            .err = "ERROR",
            .warn = "WARN",
            .info = "INFO",
            .debug = "DEBUG",
        },
        // .writers = &writers, // not possible because f.writer().any() is not comptime
        .time = .{ .gofmt = .date_time }, // .date_time is a preset but custom format is also possible
    }).init(std.heap.page_allocator, &writers, null);
    defer log.deinit(std.heap.page_allocator);

    log.debug("Hello, runtime! This will have no color if NO_COLOR is defined", .{});
    log.info("the time can be formatted like strftime or time.go", .{});
    log.scoped(.main).err("scope also works at runtime", .{});
    log.warn("this is output to stderr and log.txt", .{});
}
