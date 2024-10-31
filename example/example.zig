const std = @import("std");
const axe = @import("axe");

pub const std_options: std.Options = .{
    .logFn = axe.Comptime(.{
        .mutex = .{ .global = .{
            .lock = std.debug.lockStdErr,
            .unlock = std.debug.unlockStdErr,
        } },
    }).standardLog,
};

pub fn main() !void {
    // comptime
    const comptime_log = axe.Comptime(.{
        .styles = .none, // colored by default
        .format = "[%l]%s: %f", // the log format string, default is "%l%s: %f"
        .scope_format = " ~ %", // % is a placeholder for scope, default is "(%)"
        .level_text = .{ // same as zig by default
            .err = "ErrOr",
            .debug = "DeBuG",
        },
        // .scope = .main, // scope can also be set here, it will be ignored for std.log
        .writers = &.{std.io.getStdOut().writer().any()}, // stderr is default
        .buffering = true, // true by default
        .time = .disabled, // disabled by default, doesn't work at comptime
        .mutex = .none, // none by default
    });
    comptime_log.debug("Hello, comptime with no colors", .{});
    comptime_log.scoped(.main).err("comptime scoped", .{});

    // comptime with std.log
    // std.log supports all the features of axe.Comptime
    std.log.info("std.log.info with axe.Comptime(.{{}})", .{});
    std.log.scoped(.main).warn("this is scoped", .{});

    // runtime
    var f = try std.fs.cwd().createFile("log.txt", .{});
    defer f.close();
    const writers = [_]std.io.AnyWriter{
        std.io.getStdErr().writer().any(),
        f.writer().any(),
    };
    const log = try axe.Runtime(.{
        .format = "%t %l%s: %f",
        .scope_format = "@%",
        .styles = .{
            .err = &.{ .{ .bg_hex = "ff0000" }, .bold, .underline },
            .warn = &.{ .{ .rgb = .{ .r = 255, .g = 255, .b = 0 } }, .strikethrough },
            .info = &.{ .green, .italic },
        },
        .level_text = .{
            .err = "ERROR",
            .warn = "WARN",
            .info = "INFO",
            .debug = "DEBUG",
        },
        // .writers = &writers, // not possible because f.writer().any() is not comptime
        .time = .{ .gofmt = .date_time }, // .date_time is a preset but custom format is also possible
        .mutex = .default, // default to std.Thread.Mutex
    }).init(std.heap.page_allocator, &writers, null);
    defer log.deinit(std.heap.page_allocator);

    log.debug("Hello, runtime! This will have no color if NO_COLOR is defined", .{});
    log.info("the time can be formatted like strftime or time.go", .{});
    log.scoped(.main).err("scope also works at runtime", .{});
    log.warn("this is output to stderr and log.txt", .{});
}
