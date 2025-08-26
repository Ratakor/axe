const std = @import("std");
const axe = @import("axe");

const std_log = axe.Axe(.{
    // .progress_stderr uses std.Progress.[un]lockStdErr.
    // This specific mutex is recommended for a global stderr logger.
    .mutex = .{ .function = .progress_stderr },
});
pub const std_options: std.Options = .{
    .logFn = std_log.log,
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    var buffer: [256]u8 = undefined;

    {
        // stdout instead of stderr:
        // Note that unless .color is .always no color will be output to stdout
        // since only stderr has automatic color detection.
        const stdout_log = axe.Axe(.{
            .format = "[%l]%s: %m\n", // the log format string, default is "%l%s:%L %m\n"
            .scope_format = " ~ %", // % is a placeholder for scope, default is "(%)"
            .loc_format = "", // unused here, default is " %f:%l:"
            .time_format = .disabled, // disabled by default
            .color = .never, // .auto by default
            .styles = .none, // colored by default, useless to change here since color is never
            .level_text = .{ // same as zig by default
                .err = "ErrOr",
                .debug = "DeBuG",
            },
            .quiet = false, // disable stderr logging, default is false
            .mutex = .none, // none by default
        });
        var writer = std.fs.File.stdout().writer(&buffer);
        try stdout_log.init(allocator, &.{&writer.interface}, &env);
        defer stdout_log.deinit(allocator);

        // wait we actually don't want stderr logging let's disable it
        stdout_log.quiet = true;

        stdout_log.debug("Hello, stdout with no colors", .{});
        stdout_log.scoped(.main).err("scoped :)", .{});
    }

    {
        // std.log:
        // Init is technically optional but highly recommended, it's used to
        // check color configuration, timezone and to add new writers.
        // std.log supports all the features of axe.Axe even additional
        // writers, time or custom mutex.
        try std_log.init(allocator, null, &env);
        defer std_log.deinit(allocator);

        std.log.info("std.log.info with axe.Axe(.{{}})", .{});
        std.log.scoped(.main).warn("this is scoped", .{});
    }

    {
        // Custom writers:
        var f = try std.fs.cwd().createFile("log.txt", .{});
        defer f.close();
        const log = axe.Axe(.{
            .format = "%t %l%s%L %m\n",
            .scope_format = "@%",
            .time_format = .{ .strftime = "%Y-%m-%d %H:%M:%S" },
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
            .mutex = .default, // default to std.Thread.Mutex
        });
        var writer = f.writer(&buffer);
        try log.init(allocator, &.{&writer.interface}, &env);
        defer log.deinit(allocator);

        log.debug("Hello! This will have no color if NO_COLOR is defined or if piped", .{});
        log.scoped(.main).infoAt(@src(), "the time can be formatted like strftime or time.go", .{});
        log.errAt(@src(), "this is thread safe!", .{});
        log.warn("this is output to stderr and log.txt (without colors)", .{});
    }

    {
        // JSON log:
        var json_file = try std.fs.cwd().createFile("log.json", .{});
        defer json_file.close();
        const json_log = axe.Axe(.{
            .format =
            \\{"level":"%l",%s"time":"%t","data":%m}
            \\
            ,
            .scope_format =
            \\"scope":"%",
            ,
            .time_format = .{ .gofmt = .rfc3339 }, // .rfc3339 is a preset but custom format is also possible
            .color = .never,
        });
        var writer = json_file.writer(&buffer);
        try json_log.init(allocator, &.{&writer.interface}, &env);
        defer json_log.deinit(allocator);

        json_log.debug("\"json log\"", .{});
        json_log.scoped(.main).info("\"json scoped\"", .{});
        // It's easy to have struct instead of a string as data.
        const data = .{ .a = 42, .b = 3.14 };
        json_log.info("{f}", .{std.json.fmt(data, .{})});
    }
}
