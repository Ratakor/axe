const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const Chameleon = @import("chameleon").ComptimeChameleon;
const zeit = @import("zeit");

pub const Config = struct {
    /// The format to use for the log messages.
    /// The following specifiers are supported:
    /// - `%l`: The log level text.
    /// - `%s`: The scope text, format is specified with `scope_format`.
    /// - `%t`: The time, format is specified with `time_format`.
    /// - `%L`: The source location, format is specified with `loc_format`.
    /// - `%m`: The actual log message.
    /// - `%%`: A literal `%`.
    ///
    /// `%s` is not emitted on the default scope.
    /// `%t` is not emitted if `time_format` is `.disabled`.
    /// `%L` is not emitted if source location is not provided.
    format: []const u8 = "%l%s:%L %m\n",
    /// The format to use for the scope text.
    /// The following specifiers are supported:
    /// - `%`: The scope name.
    /// - `%%`: A literal `%`.
    scope_format: []const u8 = "(%)",
    /// The format to use for the source location provided by @src().
    /// The following specifiers are supported:
    /// - `%m`: The module name.
    /// - `%f`: The file name.
    /// - `%F`: The function name.
    /// - `%l`: The line number.
    /// - `%c`: The column number.
    /// - `%%`: A literal `%`.
    loc_format: []const u8 = " %f:%F:%l:%c:",
    /// The time format to use for the log messages.
    /// Make sure to add `%t` to `format` to display the time in logs.
    time_format: union(enum) {
        disabled,
        /// Format based on golang time package.
        gofmt: GoTimeFormat,
        /// Format based on strftime(3).
        strftime: []const u8,
    } = .disabled,
    /// Whether to enable color output.
    color: enum {
        /// Check for NO_COLOR, CLICOLOR_FORCE and tty support on stdout/stderr.
        /// Color output is disabled on other writers.
        auto,
        /// Enable color output on every writers.
        always,
        /// Disable color output on every writers.
        never,
    } = .auto,
    /// Set to `.none` to disable all styles.
    styles: Styles = .{},
    /// The text to display for each log level.
    level_text: LevelText = .{},
    /// Outputs logs to stdout.
    stdout: bool = false,
    /// Outputs logs to stderr.
    stderr: bool = true,
    /// Whether to buffer the log messages before writing them.
    buffering: bool = true,
    /// The mutex interface to use for the log messages.
    mutex: union(enum) {
        none,
        default,
        custom: type,
        function: FunctionMutex,
    } = .none,
};

/// Create a new logger based on the given configuration.
pub fn Axe(comptime config: Config) type {
    if (config.time_format == .strftime) comptime {
        var bogus: zeit.Time = .{};
        const void_writer: std.io.GenericWriter(void, error{}, struct {
            pub fn write(_: void, bytes: []const u8) error{}!usize {
                return bytes.len;
            }
        }.write) = .{ .context = {} };
        bogus.strftime(void_writer, config.time_format.strftime) catch |e|
            @compileError("Invalid strftime format: " ++ @errorName(e));
    };

    const writers_tty_config: TtyConfig = switch (config.color) {
        .always => .escape_codes,
        .auto, .never => .no_color,
    };

    return struct {
        var writers: []const std.io.AnyWriter = &.{};
        // zig/llvm can't handle this without explicit type
        var stdout: if (config.stdout) TtyConfig else void = if (config.stdout) .no_color else {};
        var stderr: if (config.stderr) TtyConfig else void = if (config.stderr) .no_color else {};
        var timezone = if (config.time_format != .disabled) zeit.utc else {};
        var mutex = switch (config.mutex) {
            .none, .function => {},
            .default => if (builtin.single_threaded) {} else std.Thread.Mutex{},
            .custom => |T| T{},
        };

        /// Setup timezone and tty configuration for stdout/stderr.
        /// This function should be called before any logging.
        /// `additional_writers` is a list of writers to write the log messages to.
        /// `additional_writers` will be duplicated so passing `&.{}` is safe.
        /// WARNING: Getting an AnyWriter with std.io.GenericWriter.any() is prone to segfaults.
        /// `env` is used to check `TZ` and `TZDIR` for the timezone.
        /// `env` is only used during initialization and is not stored.
        pub fn init(
            allocator: std.mem.Allocator,
            additional_writers: ?[]const std.io.AnyWriter,
            env: ?*const std.process.EnvMap,
        ) !void {
            if (config.time_format != .disabled) {
                timezone = try zeit.local(allocator, env);
            }
            if (additional_writers) |_writers| {
                writers = try allocator.dupe(std.io.AnyWriter, _writers);
            }
            if (config.stdout) {
                stdout = detectTtyConfig(config, std.io.getStdOut());
            }
            if (config.stderr) {
                stderr = detectTtyConfig(config, std.io.getStdErr());
            }
        }

        /// Deinitialize the logger.
        /// WARNING: After this function is called any logging is undefined behavior.
        pub fn deinit(allocator: std.mem.Allocator) void {
            if (config.time_format != .disabled) {
                timezone.deinit();
            }
            allocator.free(writers);
        }

        /// Returns a scoped logging namespace that logs all messages using the scope provided.
        pub fn scoped(comptime scope: @Type(.enum_literal)) type {
            return struct {
                /// Log an error message. This log level is intended to be used
                /// when something has gone wrong. This might be recoverable or might
                /// be followed by the program exiting.
                pub fn err(comptime format: []const u8, args: anytype) void {
                    log(.err, scope, format, args);
                }

                /// Log a warning message. This log level is intended to be used if
                /// it is uncertain whether something has gone wrong or not, but the
                /// circumstances would be worth investigating.
                pub fn warn(comptime format: []const u8, args: anytype) void {
                    log(.warn, scope, format, args);
                }

                /// Log an info message. This log level is intended to be used for
                /// general messages about the state of the program.
                pub fn info(comptime format: []const u8, args: anytype) void {
                    log(.info, scope, format, args);
                }

                /// Log a debug message. This log level is intended to be used for
                /// messages which are only useful for debugging.
                pub fn debug(comptime format: []const u8, args: anytype) void {
                    log(.debug, scope, format, args);
                }

                /// Variant of `err` that logs with a source location.
                pub fn errAt(
                    comptime src: std.builtin.SourceLocation,
                    comptime format: []const u8,
                    args: anytype,
                ) void {
                    logAt(src, .err, scope, format, args);
                }

                /// Variant of `warn` that logs with a source location.
                pub fn warnAt(
                    comptime src: std.builtin.SourceLocation,
                    comptime format: []const u8,
                    args: anytype,
                ) void {
                    logAt(src, .warn, scope, format, args);
                }

                /// Variant of `info` that logs with a source location.
                pub fn infoAt(
                    comptime src: std.builtin.SourceLocation,
                    comptime format: []const u8,
                    args: anytype,
                ) void {
                    logAt(src, .info, scope, format, args);
                }

                /// Variant of `debug` that logs with a source location.
                pub fn debugAt(
                    comptime src: std.builtin.SourceLocation,
                    comptime format: []const u8,
                    args: anytype,
                ) void {
                    logAt(src, .debug, scope, format, args);
                }
            };
        }

        /// The default scoped logging namespace.
        pub const default = scoped(.default);

        /// Log an error message using the default scope. This log level is intended to
        /// be used when something has gone wrong. This might be recoverable or might
        /// be followed by the program exiting.
        pub const err = default.err;

        /// Log a warning message using the default scope. This log level is intended
        /// to be used if it is uncertain whether something has gone wrong or not, but
        /// the circumstances would be worth investigating.
        pub const warn = default.warn;

        /// Log an info message using the default scope. This log level is intended to
        /// be used for general messages about the state of the program.
        pub const info = default.info;

        /// Log a debug message using the default scope. This log level is intended to
        /// be used for messages which are only useful for debugging.
        pub const debug = default.debug;

        /// Variant of `err` that logs with a source location.
        pub const errAt = default.errAt;

        /// Variant of `warn` that logs with a source location.
        pub const warnAt = default.warnAt;

        /// Variant of `info` that logs with a source location.
        pub const infoAt = default.infoAt;

        /// Variant of `debug` that logs with a source location.
        pub const debugAt = default.debugAt;

        /// Drop-in replacement for `std.log.defaultLog`.
        /// ```zig
        /// const Axe = @import("axe").Axe(.{});
        /// pub const std_options: std.Options = .{
        ///     .logFn = Axe.log,
        /// };
        /// ```
        pub fn log(
            comptime level: Level,
            comptime scope: @Type(.enum_literal),
            comptime format: []const u8,
            args: anytype,
        ) void {
            logAt(null, level, scope, format, args);
        }

        fn logAt(
            comptime src: ?std.builtin.SourceLocation, // should this be comptime?
            comptime level: Level,
            comptime scope: @Type(.enum_literal),
            comptime format: []const u8,
            args: anytype,
        ) void {
            if (comptime !std.log.logEnabled(level, scope)) {
                return;
            }

            switch (config.mutex) {
                .none => {},
                .function => |f| f.lock(),
                .default => if (!builtin.single_threaded) mutex.lock(),
                .custom => mutex.lock(),
            }
            defer switch (config.mutex) {
                .none => {},
                .function => |f| f.unlock(),
                .default => if (!builtin.single_threaded) mutex.unlock(),
                .custom => mutex.unlock(),
            };

            const time = if (config.time_format != .disabled) t: {
                const now = zeit.instant(.{ .timezone = &timezone }) catch unreachable;
                break :t now.time();
            } else {};

            nosuspend {
                if (config.buffering) {
                    for (writers) |writer| {
                        var bw = std.io.bufferedWriter(writer);
                        print(src, bw.writer(), writers_tty_config, time, level, scope, format, args);
                        bw.flush() catch {};
                    }
                    if (config.stdout) {
                        var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
                        print(src, bw.writer(), stdout, time, level, scope, format, args);
                        bw.flush() catch {};
                    }
                    if (config.stderr) {
                        var bw = std.io.bufferedWriter(std.io.getStdErr().writer());
                        print(src, bw.writer(), stderr, time, level, scope, format, args);
                        bw.flush() catch {};
                    }
                } else {
                    for (writers) |writer| {
                        print(src, writer, writers_tty_config, time, level, scope, format, args);
                    }
                    if (config.stdout) {
                        print(src, std.io.getStdOut().writer(), stdout, time, level, scope, format, args);
                    }
                    if (config.stderr) {
                        print(src, std.io.getStdErr().writer(), stderr, time, level, scope, format, args);
                    }
                }
            }
        }

        inline fn print(
            comptime src: ?std.builtin.SourceLocation,
            writer: anytype,
            tty_config: TtyConfig,
            time: if (config.time_format != .disabled) zeit.Time else void,
            comptime level: Level,
            comptime scope: @Type(.enum_literal),
            comptime format: []const u8,
            args: anytype,
        ) void {
            comptime var i: usize = 0;
            inline while (true) {
                const prev = i;
                i = comptime std.mem.indexOfScalarPos(u8, config.format, i, '%') orelse break;
                writer.writeAll(config.format[prev..i]) catch {};
                i += 1; // skip '%'
                if (i >= config.format.len) {
                    @compileError("Missing format specifier after `%`.");
                }
                switch (config.format[i]) {
                    'l' => writeLevel(writer, config, level, tty_config),
                    's' => if (scope != .default) {
                        writer.writeAll(comptime parseScopeFormat(config.scope_format, scope)) catch {};
                    },
                    't' => switch (config.time_format) {
                        .disabled => @compileError("Time specifier without time format."),
                        .gofmt => |gofmt| time.gofmt(writer, gofmt.fmt) catch {},
                        .strftime => |fmt| time.strftime(writer, fmt) catch {},
                    },
                    'L' => if (src) |loc| {
                        writeLocation(writer, config.loc_format, loc);
                    },
                    'm' => writer.print(format, args) catch {},
                    '%' => writer.writeAll("%") catch {},
                    else => @compileError("Unknown format specifier after `%`: `" ++ &[_]u8{config.format[i]} ++ "`."),
                }
                i += 1; // skip format specifier
            }
            if (i < config.format.len) {
                writer.writeAll(config.format[i..]) catch {};
            }
        }
    };
}

pub const Style = union(enum) {
    reset,
    bold,
    dim,
    italic,
    underline,
    blink,
    inverse,
    hidden,
    strikethrough,
    double_underline,
    overline,
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    gray,
    grey,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,
    bg_black,
    bg_red,
    bg_green,
    bg_yellow,
    bg_blue,
    bg_magenta,
    bg_cyan,
    bg_white,
    bg_bright_black,
    bg_gray,
    bg_grey,
    bg_bright_red,
    bg_bright_green,
    bg_bright_yellow,
    bg_bright_blue,
    bg_bright_magenta,
    bg_bright_cyan,
    bg_bright_white,
    rgb: struct { r: u8, g: u8, b: u8 },
    bg_rgb: struct { r: u8, g: u8, b: u8 },
    hex: []const u8,
    bg_hex: []const u8,

    fn apply(style: Style, chameleon: anytype) void {
        _ = switch (style) {
            .double_underline => chameleon.addStyle("doubleUnderline"),
            .bright_black => chameleon.addStyle("blackBright"),
            .bright_red => chameleon.addStyle("redBright"),
            .bright_green => chameleon.addStyle("greenBright"),
            .bright_yellow => chameleon.addStyle("yellowBright"),
            .bright_blue => chameleon.addStyle("blueBright"),
            .bright_magenta => chameleon.addStyle("magentaBright"),
            .bright_cyan => chameleon.addStyle("cyanBright"),
            .bright_white => chameleon.addStyle("whiteBright"),
            .bg_black => chameleon.addStyle("bgBlack"),
            .bg_red => chameleon.addStyle("bgRed"),
            .bg_green => chameleon.addStyle("bgGreen"),
            .bg_yellow => chameleon.addStyle("bgYellow"),
            .bg_blue => chameleon.addStyle("bgBlue"),
            .bg_magenta => chameleon.addStyle("bgMagenta"),
            .bg_cyan => chameleon.addStyle("bgCyan"),
            .bg_white => chameleon.addStyle("bgWhite"),
            .bg_bright_black => chameleon.addStyle("bgBlackBright"),
            .bg_bright_red => chameleon.addStyle("bgRedBright"),
            .bg_bright_green => chameleon.addStyle("bgGreenBright"),
            .bg_bright_yellow => chameleon.addStyle("bgYellowBright"),
            .bg_bright_blue => chameleon.addStyle("bgBlueBright"),
            .bg_bright_magenta => chameleon.addStyle("bgMagentaBright"),
            .bg_bright_cyan => chameleon.addStyle("bgCyanBright"),
            .bg_bright_white => chameleon.addStyle("bgWhiteBright"),
            .rgb => |rgb| chameleon.rgb(rgb.r, rgb.g, rgb.b),
            .bg_rgb => |rgb| chameleon.bgRgb(rgb.r, rgb.g, rgb.b),
            .hex => |hex| chameleon.hex(hex),
            .bg_hex => |hex| chameleon.bgHex(hex),
            else => chameleon.addStyle(@tagName(style)),
        };
    }

    fn applyWindows(style: Style, ctx: TtyConfig.WindowsContext) !void {
        const attributes = switch (style) {
            .black => 0,
            .red => windows.FOREGROUND_RED,
            .green => windows.FOREGROUND_GREEN,
            .yellow => windows.FOREGROUND_RED | windows.FOREGROUND_GREEN,
            .blue => windows.FOREGROUND_BLUE,
            .magenta => windows.FOREGROUND_RED | windows.FOREGROUND_BLUE,
            .cyan => windows.FOREGROUND_GREEN | windows.FOREGROUND_BLUE,
            .white => windows.FOREGROUND_RED | windows.FOREGROUND_GREEN | windows.FOREGROUND_BLUE,
            .bright_black => windows.FOREGROUND_INTENSITY,
            .bright_red => windows.FOREGROUND_RED | windows.FOREGROUND_INTENSITY,
            .bright_green => windows.FOREGROUND_GREEN | windows.FOREGROUND_INTENSITY,
            .bright_yellow => windows.FOREGROUND_RED | windows.FOREGROUND_GREEN | windows.FOREGROUND_INTENSITY,
            .bright_blue => windows.FOREGROUND_BLUE | windows.FOREGROUND_INTENSITY,
            .bright_magenta => windows.FOREGROUND_RED | windows.FOREGROUND_BLUE | windows.FOREGROUND_INTENSITY,
            .bright_cyan => windows.FOREGROUND_GREEN | windows.FOREGROUND_BLUE | windows.FOREGROUND_INTENSITY,
            .bright_white, .bold => windows.FOREGROUND_RED | windows.FOREGROUND_GREEN | windows.FOREGROUND_BLUE | windows.FOREGROUND_INTENSITY,
            // "dim" is not supported using basic character attributes, but let's still make it do *something*.
            .dim => windows.FOREGROUND_INTENSITY,
            .reset => ctx.reset_attributes,
            else => return,
        };
        try windows.SetConsoleTextAttribute(ctx.handle, attributes);
    }
};

pub const Styles = struct {
    err: []const Style = &.{ .bold, .red },
    warn: []const Style = &.{ .bold, .yellow },
    info: []const Style = &.{ .bold, .blue },
    debug: []const Style = &.{ .bold, .cyan },

    pub const none: Styles = .{
        .err = &.{},
        .warn = &.{},
        .info = &.{},
        .debug = &.{},
    };
};

pub const Level = std.log.Level;

pub const LevelText = struct {
    err: []const u8 = "error",
    warn: []const u8 = "warning",
    info: []const u8 = "info",
    debug: []const u8 = "debug",
};

pub const GoTimeFormat = struct {
    fmt: []const u8,

    // constants based on https://pkg.go.dev/time#pkg-constants
    pub const ansi_c: GoTimeFormat = .{ .fmt = "Mon Jan _2 15:04:05 2006" };
    pub const unix_date: GoTimeFormat = .{ .fmt = "Mon Jan _2 15:04:05 MST 2006" };
    pub const ruby_date: GoTimeFormat = .{ .fmt = "Mon Jan 02 15:04:05 -0700 2006" };
    pub const rfc822: GoTimeFormat = .{ .fmt = "02 Jan 06 15:04 MST" };
    /// RFC822 with numeric zone
    pub const rfc822z: GoTimeFormat = .{ .fmt = "02 Jan 06 15:04 -0700" };
    pub const rfc850: GoTimeFormat = .{ .fmt = "Monday, 02-Jan-06 15:04:05 MST" };
    pub const rfc1123: GoTimeFormat = .{ .fmt = "Mon, 02 Jan 2006 15:04:05 MST" };
    /// RFC1123 with numeric zone
    pub const rfc1123z: GoTimeFormat = .{ .fmt = "Mon, 02 Jan 2006 15:04:05 -0700" };
    pub const rfc3339: GoTimeFormat = .{ .fmt = "2006-01-02T15:04:05Z07:00" };
    pub const rfc3339nano: GoTimeFormat = .{ .fmt = "2006-01-02T15:04:05.999999999Z07:00" };
    pub const kitchen: GoTimeFormat = .{ .fmt = "3:04PM" };
    // Handy time stamps.
    pub const stamp: GoTimeFormat = .{ .fmt = "Jan _2 15:04:05" };
    pub const stamp_milli: GoTimeFormat = .{ .fmt = "Jan _2 15:04:05.000" };
    pub const stamp_micro: GoTimeFormat = .{ .fmt = "Jan _2 15:04:05.000000" };
    pub const stamp_nano: GoTimeFormat = .{ .fmt = "Jan _2 15:04:05.000000000" };
    pub const date_time: GoTimeFormat = .{ .fmt = "2006-01-02 15:04:05" };
    pub const date_only: GoTimeFormat = .{ .fmt = "2006-01-02" };
    pub const time_only: GoTimeFormat = .{ .fmt = "15:04:05" };
};

pub const FunctionMutex = struct {
    lock: fn () void,
    unlock: fn () void,

    pub const progress_stderr: FunctionMutex = .{
        .lock = std.Progress.lockStdErr,
        .unlock = std.Progress.unlockStdErr,
    };
};

/// Extracted from std.io.tty
const TtyConfig = union(enum) {
    no_color,
    escape_codes,
    windows_api: if (builtin.os.tag == .windows) WindowsContext else void,

    const WindowsContext = struct {
        handle: windows.HANDLE,
        reset_attributes: windows.WORD,
    };

    /// Detect suitable TTY configuration options for the given file (commonly stdout/stderr).
    /// This includes feature checks for ANSI escape codes and the Windows console API, as well as
    /// respecting the `NO_COLOR` and `CLICOLOR_FORCE` environment variables to override the default.
    /// Will attempt to enable ANSI escape code support if necessary/possible.
    fn detectConfig(file: std.fs.File) TtyConfig {
        const force_color: ?bool = if (builtin.os.tag == .wasi)
            null // wasi does not support environment variables
        else if (std.process.hasEnvVarConstant("NO_COLOR"))
            false
        else if (std.process.hasEnvVarConstant("CLICOLOR_FORCE"))
            true
        else
            null;

        if (force_color == false) return .no_color;

        if (file.getOrEnableAnsiEscapeSupport()) return .escape_codes;

        if (builtin.os.tag == .windows and file.isTty()) {
            var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
            if (windows.kernel32.GetConsoleScreenBufferInfo(file.handle, &info) == windows.FALSE) {
                return if (force_color == true) .escape_codes else .no_color;
            }
            return .{ .windows_api = .{
                .handle = file.handle,
                .reset_attributes = info.wAttributes,
            } };
        }

        return if (force_color == true) .escape_codes else .no_color;
    }
};

inline fn detectTtyConfig(comptime config: Config, file: std.fs.File) TtyConfig {
    return switch (config.color) {
        .auto => TtyConfig.detectConfig(file),
        .always => switch (TtyConfig.detectConfig(file)) {
            .no_color, .escape_codes => .escape_codes,
            .windows_api => |ctx| .{ .windows_api = ctx },
        },
        .never => .no_color,
    };
}

fn writeLevel(
    writer: anytype,
    comptime config: Config,
    comptime level: Level,
    tty_config: TtyConfig,
) void {
    switch (tty_config) {
        .no_color => writer.writeAll(@field(config.level_text, @tagName(level))) catch {},
        .escape_codes => {
            comptime var chameleon: Chameleon = .{};
            comptime for (@field(config.styles, @tagName(level))) |style| {
                Style.apply(style, &chameleon);
            };
            const text = comptime chameleon.fmt(@field(config.level_text, @tagName(level)));
            writer.writeAll(text) catch {};
        },
        .windows_api => |ctx| if (builtin.os.tag == .windows) {
            inline for (@field(config.styles, @tagName(level))) |style| {
                Style.applyWindows(style, ctx) catch {};
            }
            writer.writeAll(@field(config.level_text, @tagName(level))) catch {};
            Style.applyWindows(.reset, ctx) catch {};
        } else unreachable,
    }
}

fn parseScopeFormat(comptime format: []const u8, comptime scope: @Type(.enum_literal)) []const u8 {
    comptime {
        var text: []const u8 = "";
        var i: usize = 0;
        while (i < format.len) : (i += 1) {
            switch (format[i]) {
                '%' => if (i + 1 >= format.len or format[i + 1] != '%') {
                    text = text ++ @tagName(scope);
                } else {
                    text = text ++ "%";
                    i += 1;
                },
                else => text = text ++ &[_]u8{format[i]},
            }
        }
        return text;
    }
}

fn writeLocation(
    writer: anytype,
    comptime format: []const u8,
    loc: std.builtin.SourceLocation,
) void {
    comptime var i: usize = 0;
    inline while (i < format.len) : (i += 1) {
        switch (format[i]) {
            '%' => {
                i += 1; // skip '%'
                if (i >= format.len) {
                    @compileError("Missing loc_format specifier after `%`.");
                }
                switch (format[i]) {
                    'm' => writer.writeAll(loc.module) catch {},
                    'f' => writer.writeAll(loc.file) catch {},
                    'F' => writer.writeAll(loc.fn_name) catch {},
                    'l' => writer.print("{d}", .{loc.line}) catch {},
                    'c' => writer.print("{d}", .{loc.column}) catch {},
                    '%' => writer.writeAll("%") catch {},
                    else => @compileError("Unknown loc_format specifier after `%`: `" ++ &[_]u8{format[i]} ++ "`."),
                }
            },
            else => writer.writeByte(format[i]) catch {},
        }
    }
}

test "log without styles" {
    const expectEqualStrings = std.testing.expectEqualStrings;
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();

    const log = Axe(.{
        .styles = .none,
        .stderr = false,
        .buffering = false,
    });
    try log.init(std.testing.allocator, &.{list.writer().any()}, null); // testing with maybe wrong writer
    defer log.deinit(std.testing.allocator);

    log.info("Hello, {s}!", .{"world"});
    try expectEqualStrings("info: Hello, world!\n", list.items);
    list.resize(0) catch unreachable;

    log.scoped(.my_scope).warn("", .{});
    try expectEqualStrings("warning(my_scope): \n", list.items);
    list.resize(0) catch unreachable;

    log.scoped(.other_scope).err("`{s}` not found: {}", .{ "test.txt", error.FileNotFound });
    try expectEqualStrings("error(other_scope): `test.txt` not found: error.FileNotFound\n", list.items);
    list.resize(0) catch unreachable;
}

test "log with complex config" {
    const expectEqualStrings = std.testing.expectEqualStrings;
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    comptime var chameleon: Chameleon = .{};

    const log = Axe(.{
        .format = "[%l]%s: %m", // no newline
        .scope_format = " %% %",
        .loc_format = "", // can't test because it's inconsistent
        .time_format = .disabled, // can't test because it's inconsistent
        .styles = .{
            .err = &.{.red},
            .warn = &.{.yellow},
            .info = &.{.blue},
            .debug = &.{.cyan},
        },
        .level_text = .{
            .err = "ERROR",
            .warn = "WARNING",
            .info = "INFO",
            .debug = "DEBUG",
        },
        .color = .always,
        .stderr = false,
        .buffering = false,
        .mutex = .default,
    });
    try log.init(std.testing.allocator, &.{arrayListWriter(&list)}, null);
    defer log.deinit(std.testing.allocator);

    log.info("Hello, {s}!", .{"world"});
    try expectEqualStrings("[" ++ chameleon.blue().fmt("INFO") ++ "]: Hello, world!", list.items);
    list.resize(0) catch unreachable;

    log.scoped(.my_scope).warn("", .{});
    try expectEqualStrings("[" ++ chameleon.yellow().fmt("WARNING") ++ "] % my_scope: ", list.items);
    list.resize(0) catch unreachable;

    log.scoped(.other_scope).err("`{s}` not found: {}", .{ "test.txt", error.FileNotFound });
    try expectEqualStrings(
        "[" ++ chameleon.red().fmt("ERROR") ++ "] % other_scope: `test.txt` not found: error.FileNotFound",
        list.items,
    );
    list.resize(0) catch unreachable;
}

test "json log" {
    const expectEqualStrings = std.testing.expectEqualStrings;
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();

    const log = Axe(.{
        .format =
        \\{"level":"%l",%s"data":%m}
        \\
        ,
        .scope_format =
        \\"scope":"%",
        ,
        .stderr = false,
        .color = .never,
        .buffering = false,
    });
    try log.init(std.testing.allocator, &.{arrayListWriter(&list)}, null);
    defer log.deinit(std.testing.allocator);

    log.debug("\"json log\"", .{});
    try expectEqualStrings(
        \\{"level":"debug","data":"json log"}
        \\
    , list.items);
    list.resize(0) catch unreachable;

    log.scoped(.main).info("\"json scoped\"", .{});
    try expectEqualStrings(
        \\{"level":"info","scope":"main","data":"json scoped"}
        \\
    , list.items);
    list.resize(0) catch unreachable;

    const data = .{ .a = 42, .b = 3.14 };
    log.info("{}", .{std.json.fmt(data, .{})});
    try expectEqualStrings(
        \\{"level":"info","data":{"a":42,"b":3.14e0}}
        \\
    , list.items);
    list.resize(0) catch unreachable;
}

fn arrayListWriter(list: *std.ArrayList(u8)) std.io.AnyWriter {
    return .{
        .context = @ptrCast(list),
        .writeFn = struct {
            fn typeErasedWrite(context: *const anyopaque, bytes: []const u8) !usize {
                const self: *std.ArrayList(u8) = @constCast(@ptrCast(@alignCast(context)));
                try self.appendSlice(bytes);
                return bytes.len;
            }
        }.typeErasedWrite,
    };
}
