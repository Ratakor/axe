const std = @import("std");
const builtin = @import("builtin");
const axe = @import("axe");

const std_log = axe.Axe(.{
    // .progress_stderr uses std.Progress.[un]lockStdErr
    // it's not necessary but recommended for a global stderr logger
    .mutex = .{ .function = .progress_stderr },
});
pub const std_options: std.Options = .{
    .logFn = std_log.log,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    // stdout instead of stderr:
    // note that unless .color is .always no color will be output to stdout
    // only stderr has automatic color detection
    const stdout_log = axe.Axe(.{
        .format = "[%l]%s: %m\n", // the log format string, default is "%l%s:%L %m\n"
        .scope_format = " ~ %", // % is a placeholder for scope, default is "(%)"
        .loc_format = "", // unused here, default is " %f:%l:"
        .time_format = .disabled, // disabled by default
        .color = .never, // auto by default
        .styles = .none, // colored by default, useless to change here since color is never
        .level_text = .{ // same as zig by default
            .err = "ErrOr",
            .debug = "DeBuG",
        },
        .quiet = true, // disable stderr logging, default is false
        .buffering = true, // default is true
        .mutex = .none, // none by default
    });
    try stdout_log.init(allocator, &.{fileWriter(std.io.getStdOut())}, &env);
    defer stdout_log.deinit(allocator);
    stdout_log.debug("Hello, stdout with no colors", .{});
    stdout_log.scoped(.main).err("scoped :)", .{});

    // std.log:
    // init is technically optional but highly recommened, it's used to check
    //   color configuration, timezone and to add new writers.
    // std.log supports all the features of axe.Axe even additional writers, time or custom mutex.
    try std_log.init(allocator, null, &env);
    defer std_log.deinit(allocator);
    std.log.info("std.log.info with axe.Axe(.{{}})", .{});
    std.log.scoped(.main).warn("this is scoped", .{});

    // custom writers:
    var f = try std.fs.cwd().createFile("log.txt", .{});
    defer f.close();
    const log = axe.Axe(.{
        .format = "%t %l%s%L %m\n",
        .scope_format = "@%",
        .time_format = .{ .gofmt = .date_time }, // .date_time is a preset but custom format is also possible
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
    // Note that we're using .any() to convert std.io.GenericWriter to std.io.AnyWriter.
    // It is highly recommended to instead implement std.io.AnyWriter because .any()
    //   uses a pointer to the GenericWriter context which could create a dangling pointer.
    // See `fileWriter` for an example of how to implement std.io.AnyWriter for a file.
    // See `arrayListWriter` in axe.zig for another example with ArrayList(u8).
    try log.init(allocator, &.{f.writer().any()}, &env);
    defer log.deinit(allocator);

    log.debug("Hello! This will have no color if NO_COLOR is defined or if piped", .{});
    log.scoped(.main).infoAt(@src(), "the time can be formatted like strftime or time.go", .{});
    log.errAt(@src(), "this is thread safe!", .{});
    log.warn("this is output to stderr and log.txt (without colors)", .{});

    // json log:
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
        .time_format = .{ .gofmt = .rfc3339 },
        .color = .never,
    });
    try json_log.init(allocator, &.{fileWriter(json_file)}, &env);
    defer json_log.deinit(allocator);

    json_log.debug("\"json log\"", .{});
    json_log.scoped(.main).info("\"json scoped\"", .{});
    // it's easy to have struct instead of a string as data
    const data = .{ .a = 42, .b = 3.14 };
    json_log.info("{}", .{std.json.fmt(data, .{})});
}

fn fileWriter(file: std.fs.File) std.io.AnyWriter {
    if (builtin.os.tag == .windows) {
        return fileWriterWindows(file);
    } else {
        return fileWriterPosix(file);
    }
}

fn fileWriterPosix(file: std.fs.File) std.io.AnyWriter {
    // It's fine to store the handle as the pointer here because it's small enough to fit in.
    return .{
        .context = @ptrFromInt(@as(usize, @intCast(file.handle))),
        .writeFn = struct {
            fn typeErasedWrite(context: *const anyopaque, bytes: []const u8) !usize {
                const self: std.fs.File = .{ .handle = @intCast(@intFromPtr(context)) };
                return self.write(bytes);
            }
        }.typeErasedWrite,
    };
}

fn fileWriterWindows(file: std.fs.File) std.io.AnyWriter {
    return .{
        .context = file.handle,
        .writeFn = struct {
            fn typeErasedWrite(context: *const anyopaque, bytes: []const u8) !usize {
                const self: std.fs.File = .{ .handle = @constCast(context) };
                return self.write(bytes);
            }
        }.typeErasedWrite,
    };
}
