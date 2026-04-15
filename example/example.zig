const std = @import("std");
const axe = @import("axe");

const std_log = axe.Axe(.{});

pub const std_options: std.Options = .{
    .logFn = std_log.log,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const env = init.environ_map;
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
            .mutex = .none, // default is based on builtin.single_threaded
        });
        var writer = std.Io.File.stdout().writer(io, &buffer);
        try stdout_log.init(io, &.{&writer.interface}, env);
        defer stdout_log.deinit();

        // wait we actually don't want stderr logging let's disable it
        stdout_log.quiet = true;

        stdout_log.debug("Hello, stdout with no colors", .{});
        stdout_log.scoped(.main).err("scoped :)", .{});
    }

    {
        // std.log:
        // Init is used to check color configuration, timezone and to add new
        //   writers, it should be called at the very start of the program.
        // std.log supports all the features of axe.Axe even additional writers,
        //   time or custom mutex.
        try std_log.init(io, null, env);
        defer std_log.deinit();

        std.log.info("std.log.info with axe.Axe(.{{}})", .{});

        // actually we want forced colors, try running with NO_COLOR=1
        std_log.setTerminalMode(.always, env);

        std.log.scoped(.main).warn("this is scoped", .{});
    }

    {
        // Custom writers:
        var f = try std.Io.Dir.cwd().createFile(io, "log.txt", .{});
        defer f.close(io);
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
            .mutex = .default,
        });
        var writer = f.writer(io, &buffer);
        try log.init(io, &.{&writer.interface}, env);
        defer log.deinit();

        log.debug("Hello! This will have no color if NO_COLOR is defined or if piped", .{});
        log.scoped(.main).infoAt(@src(), "the time can be formatted like strftime or time.go", .{});
        log.errAt(@src(), "this is thread safe!", .{});
        log.warn("this is output to stderr and log.txt (without colors)", .{});
    }

    {
        // JSON log:
        var json_file = try std.Io.Dir.cwd().createFile(io, "log.json", .{});
        defer json_file.close(io);
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
        var writer = json_file.writer(io, &buffer);
        try json_log.init(io, &.{&writer.interface}, env);
        defer json_log.deinit();

        json_log.debug("\"json log\"", .{});
        json_log.scoped(.main).info("\"json scoped\"", .{});
        // It's easy to have struct instead of a string as data.
        const data = .{ .a = 42, .b = 3.14 };
        json_log.info("{f}", .{std.json.fmt(data, .{})});
    }
}
