const std = @import("std");
const builtin = @import("builtin");
const axe = @import("axe");

const std_log = axe.Axe(.{
    // this is not necessary but it's used in std.log.defaultLog so we keep it
    .mutex = .{ .function = .{
        .lock = std.debug.lockStdErr,
        .unlock = std.debug.unlockStdErr,
    } },
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

    // std.log:
    // init is technically optional but highly recommened, it's used to check
    //   color configuration, timezone and to add new writers.
    // std.log supports all the features of axe.Axe even additional writers, time or custom mutex.
    try std_log.init(allocator, &.{}, &env);
    defer std_log.deinit(allocator);
    std.log.info("std.log.info with axe.Axe(.{{}})", .{});
    std.log.scoped(.main).warn("this is scoped", .{});

    // stdout instead of stderr:
    const stdout_log = axe.Axe(.{
        .format = "[%l]%s: %f\n", // the log format string, default is "%l%s: %f\n"
        .scope_format = " ~ %", // % is a placeholder for scope, default is "(%)"
        .color = .never, // auto by default
        .styles = .none, // colored by default, useless to change here since color is never
        .level_text = .{ // same as zig by default
            .err = "ErrOr",
            .debug = "DeBuG",
        },
        .stdout = true, // default is false
        .stderr = false, // default is true
        .buffering = true, // default is true
        .time = .disabled, // disabled by default, doesn't work at comptime
        .mutex = .none, // none by default
    });
    // no need for init since there is no color, no time and no writer
    stdout_log.debug("Hello, stdout with no colors", .{});
    stdout_log.scoped(.main).err("scoped :)", .{});

    // custom writers:
    var f = try std.fs.cwd().createFile("log.txt", .{});
    defer f.close();
    const log = axe.Axe(.{
        .format = "%t %l%s: %f\n",
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
        .time = .{ .gofmt = .date_time }, // .date_time is a preset but custom format is also possible
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
    log.scoped(.main).info("the time can be formatted like strftime or time.go", .{});
    log.err("this is thread safe!", .{});
    log.warn("this is output to stderr and log.txt (without colors)", .{});

    // json log:
    var json_file = try std.fs.cwd().createFile("log.json", .{});
    defer json_file.close();
    const json_log = axe.Axe(.{
        .format =
        \\{"level":"%l",%s"time":"%t","data":%f}
        \\
        ,
        .scope_format =
        \\"scope":"%",
        ,
        .stderr = false,
        .color = .never,
        .time = .{ .gofmt = .rfc3339 },
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
