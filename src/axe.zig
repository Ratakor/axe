const std = @import("std");
const builtin = @import("builtin");
const zeit = @import("zeit");
const windows = std.os.windows;
const tty = std.io.tty;

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
    loc_format: []const u8 = " %f:%l:",
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
        /// Check for NO_COLOR, CLICOLOR_FORCE and tty support on stderr.
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
    /// Whether to write log messages to stderr.
    quiet: bool = false,
    /// Whether to flush writers after every log.
    flush_each_log: bool = true,
    /// The mutex interface to use for the log messages.
    mutex: union(enum) {
        none,
        default,
        custom: type,
        function: FunctionMutex,
    } = .none,
};

fn discardDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) !usize {
    var total: usize = w.end;
    for (data) |chunk| {
        total += chunk.len;
    }
    _ = splat;
    w.end = 0;
    return total;
}

/// Create a new logger based on the given configuration.
pub fn Axe(comptime config: Config) type {
    if (config.time_format == .strftime) comptime {
        var bogus: zeit.Time = .{};
        var void_writer: std.Io.Writer = .{
            .vtable = &.{
                .drain = discardDrain,
                .flush = std.Io.Writer.noopFlush,
            },
            .buffer = &.{},
        };
        bogus.strftime(&void_writer, config.time_format.strftime) catch |e|
            @compileError("Invalid strftime format: " ++ @errorName(e));
    };

    const writers_tty_config: tty.Config = switch (config.color) {
        .always => .escape_codes,
        .auto, .never => .no_color,
    };

    return struct {
        var writers: []*std.Io.Writer = &.{};
        // zig/llvm can't handle this without explicit type
        var stderr_tty_config: if (config.quiet) void else tty.Config = if (config.quiet) {} else .no_color;
        var stderr_buffer: [256]u8 = undefined;
        var timezone = if (config.time_format != .disabled) zeit.utc else {};
        var mutex = switch (config.mutex) {
            .none, .function => {},
            .default => if (builtin.single_threaded) {} else std.Thread.Mutex{},
            .custom => |T| T{},
        };

        /// Setup timezone and tty configuration for stderr.
        /// This function should be called before any logging.
        /// `additional_writers` is a list of writers to write the log messages to.
        /// `additional_writers` will be duplicated so passing `&.{}` is safe.
        /// WARNING: Getting an AnyWriter with std.io.GenericWriter.any() is prone to segfaults.
        /// `env` is used to check `TZ` and `TZDIR` for the timezone.
        /// `env` is only used during initialization and is not stored.
        pub fn init(
            allocator: std.mem.Allocator,
            additional_writers: ?[]const *std.Io.Writer,
            env: ?*const std.process.EnvMap,
        ) !void {
            if (config.time_format != .disabled) {
                timezone = try zeit.local(allocator, env);
            }
            if (additional_writers) |_writers| {
                writers = try allocator.dupe(*std.Io.Writer, _writers);
            }
            if (!config.quiet) {
                stderr_tty_config = switch (config.color) {
                    .auto => .detect(std.fs.File.stderr()),
                    .always => if (builtin.os.tag == .windows) switch (.detect(std.fs.File.stderr())) {
                        .no_color, .escape_codes => .escape_codes,
                        .windows_api => |ctx| .{ .windows_api = ctx },
                    } else .escape_codes,
                    .never => .no_color,
                };
            }
        }

        /// Deinitialize the logger.
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
                for (writers) |writer| {
                    print(src, writer, writers_tty_config, time, level, scope, format, args);
                    if (config.flush_each_log) {
                        writer.flush() catch {};
                    }
                }
                if (!config.quiet) {
                    var standard_error = std.fs.File.stderr().writer(&stderr_buffer);
                    print(src, &standard_error.interface, stderr_tty_config, time, level, scope, format, args);
                    if (config.flush_each_log) {
                        standard_error.interface.flush() catch {};
                    }
                }
            }
        }

        fn print(
            comptime src: ?std.builtin.SourceLocation,
            writer: *std.Io.Writer,
            tty_config: tty.Config,
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
                    'l' => callWithStyles(
                        writer,
                        tty_config,
                        @field(config.styles, @tagName(level)),
                        writeAllCallback,
                        .{ writer, @field(config.level_text, @tagName(level)) },
                    ),
                    's' => if (scope != .default) callWithStyles(
                        writer,
                        tty_config,
                        config.styles.scope,
                        writeAllCallback,
                        .{ writer, comptime parseScopeFormat(config.scope_format, scope) },
                    ),
                    't' => if (config.time_format != .disabled) callWithStyles(
                        writer,
                        tty_config,
                        config.styles.time,
                        writeTimeCallback,
                        .{ writer, time },
                    ) else @compileError("Time specifier without time format."),
                    'L' => if (src) |loc| callWithStyles(
                        writer,
                        tty_config,
                        config.styles.loc,
                        writeLocation,
                        .{ writer, config.loc_format, loc },
                    ),
                    'm' => callWithStyles(
                        writer,
                        tty_config,
                        config.styles.message,
                        printCallback,
                        .{ writer, format, args },
                    ),
                    '%' => writer.writeAll("%") catch {},
                    else => @compileError("Unknown format specifier after `%`: `" ++ &[_]u8{config.format[i]} ++ "`."),
                }
                i += 1; // skip format specifier
            }
            if (i < config.format.len) {
                writer.writeAll(config.format[i..]) catch {};
            }
        }

        inline fn writeTimeCallback(writer: *std.Io.Writer, time: zeit.Time) void {
            switch (config.time_format) {
                .disabled => unreachable,
                .gofmt => |gofmt| time.gofmt(writer, gofmt.fmt) catch {},
                .strftime => |fmt| time.strftime(writer, fmt) catch {},
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
    /// #RRGGBB, #RGB, RRGGBB, RGB
    hex: []const u8,
    bg_hex: []const u8,

    inline fn fmt(comptime styles: []const Style, comptime text: []const u8) []const u8 {
        comptime {
            const open, const close = makeStyles(styles);
            return open ++ text ++ close;
        }
    }

    fn makeStyles(comptime styles: []const Style) [2][]const u8 {
        comptime {
            var open: []const u8 = "";
            var close: []const u8 = "";
            for (styles) |style| {
                const esc = wrap(style.values());
                open = open ++ esc[0];
                close = esc[1] ++ close;
            }
            return .{ open, close };
        }
    }

    fn wrap(comptime style: [2][]const u8) [2][]const u8 {
        const csi = "\x1b[";
        return [2][]const u8{
            csi ++ style[0] ++ "m",
            csi ++ style[1] ++ "m",
        };
    }

    fn values(comptime style: Style) [2][]const u8 {
        return comptime switch (style) {
            .reset => [2][]const u8{ "0", "0" },
            .bold => [2][]const u8{ "1", "22" },
            .dim => [2][]const u8{ "2", "22" },
            .italic => [2][]const u8{ "3", "23" },
            .underline => [_][]const u8{ "4", "24" },
            .blink => [2][]const u8{ "5", "25" },
            .inverse => [2][]const u8{ "7", "27" },
            .hidden => [2][]const u8{ "8", "28" },
            .strikethrough => [2][]const u8{ "9", "29" },
            .double_underline => [2][]const u8{ "21", "24" },
            .overline => [2][]const u8{ "53", "55" },

            .black => [2][]const u8{ "30", "39" },
            .red => [2][]const u8{ "31", "39" },
            .green => [2][]const u8{ "32", "39" },
            .yellow => [2][]const u8{ "33", "39" },
            .blue => [2][]const u8{ "34", "39" },
            .magenta => [2][]const u8{ "35", "39" },
            .cyan => [2][]const u8{ "36", "39" },
            .white => [2][]const u8{ "37", "39" },

            .bright_black, .gray, .grey => [2][]const u8{ "90", "39" },
            .bright_red => [2][]const u8{ "91", "39" },
            .bright_green => [2][]const u8{ "92", "39" },
            .bright_yellow => [2][]const u8{ "93", "39" },
            .bright_blue => [2][]const u8{ "94", "39" },
            .bright_magenta => [2][]const u8{ "95", "39" },
            .bright_cyan => [2][]const u8{ "96", "39" },
            .bright_white => [2][]const u8{ "97", "39" },

            .bg_black => [2][]const u8{ "40", "49" },
            .bg_red => [2][]const u8{ "41", "49" },
            .bg_green => [2][]const u8{ "42", "49" },
            .bg_yellow => [2][]const u8{ "43", "49" },
            .bg_blue => [2][]const u8{ "44", "49" },
            .bg_magenta => [2][]const u8{ "45", "49" },
            .bg_cyan => [2][]const u8{ "46", "49" },
            .bg_white => [2][]const u8{ "47", "49" },

            .bg_bright_black, .bg_gray, .bg_grey => [2][]const u8{ "100", "49" },
            .bg_bright_red => [2][]const u8{ "101", "49" },
            .bg_bright_green => [2][]const u8{ "102", "49" },
            .bg_bright_yellow => [2][]const u8{ "103", "49" },
            .bg_bright_blue => [2][]const u8{ "104", "49" },
            .bg_bright_magenta => [2][]const u8{ "105", "49" },
            .bg_bright_cyan => [2][]const u8{ "106", "49" },
            .bg_bright_white => [2][]const u8{ "107", "49" },

            .rgb => |rgb| [2][]const u8{
                "38;2;" ++ std.fmt.comptimePrint("{d};{d};{d}", .{ rgb.r, rgb.g, rgb.b }),
                "39",
            },
            .bg_rgb => |rgb| [2][]const u8{
                "48;2;" ++ std.fmt.comptimePrint("{d};{d};{d}", .{ rgb.r, rgb.g, rgb.b }),
                "49",
            },
            .hex => |hex| [2][]const u8{
                "38;2;" ++ rgbFromHex(hex),
                "39",
            },
            .bg_hex => |hex| [2][]const u8{
                "48;2;" ++ rgbFromHex(hex),
                "49",
            },
        };
    }

    fn rgbFromHex(comptime hex_code: []const u8) []const u8 {
        comptime {
            const hex = if (hex_code[0] == '#') hex_code[1..] else hex_code;
            const hex_final = if (hex.len == 3)
                &[6]u8{ hex[0], hex[0], hex[1], hex[1], hex[2], hex[2] }
            else
                hex;
            if (hex_final.len != 6) {
                @compileError("Invalid hex color code length.");
            }
            const hex_int = std.fmt.parseUnsigned(u32, hex_final, 16) catch |err|
                @compileError("Invalid hex color code: " ++ @errorName(err));
            return std.fmt.comptimePrint("{d};{d};{d}", .{
                (hex_int >> 16) & 0xff,
                (hex_int >> 8) & 0xff,
                hex_int & 0xff,
            });
        }
    }

    fn applyWindows(style: Style, ctx: tty.Config.WindowsContext) void {
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
        windows.SetConsoleTextAttribute(ctx.handle, attributes) catch unreachable;
    }
};

pub const Styles = struct {
    // levels
    err: []const Style = &.{ .bold, .red },
    warn: []const Style = &.{ .bold, .yellow },
    info: []const Style = &.{ .bold, .blue },
    debug: []const Style = &.{ .bold, .cyan },

    scope: []const Style = &.{},
    time: []const Style = &.{.white},
    loc: []const Style = &.{.dim},
    message: []const Style = &.{},

    pub const none: Styles = .{
        .err = &.{},
        .warn = &.{},
        .info = &.{},
        .debug = &.{},
        .scope = &.{},
        .time = &.{},
        .loc = &.{},
        .message = &.{},
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

inline fn callWithStyles(
    writer: *std.Io.Writer,
    tty_config: tty.Config,
    comptime styles: []const Style,
    comptime callback: anytype,
    args: anytype,
) void {
    switch (tty_config) {
        .no_color => @call(.auto, callback, args),
        .escape_codes => {
            const open, const close = comptime Style.makeStyles(styles);
            writer.writeAll(open) catch {};
            @call(.auto, callback, args);
            writer.writeAll(close) catch {};
        },
        .windows_api => |ctx| if (builtin.os.tag == .windows) {
            inline for (styles) |style| {
                Style.applyWindows(style, ctx);
            }
            @call(.auto, callback, args);
            Style.applyWindows(.reset, ctx);
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

inline fn writeAllCallback(writer: *std.Io.Writer, bytes: []const u8) void {
    writer.writeAll(bytes) catch {};
}

inline fn printCallback(writer: *std.Io.Writer, comptime format: []const u8, args: anytype) void {
    writer.print(format, args) catch {};
}

fn writeLocation(
    writer: *std.Io.Writer,
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
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const log = Axe(.{
        .styles = .none,
        .quiet = true,
    });
    try log.init(std.testing.allocator, &.{&writer}, null);
    defer log.deinit(std.testing.allocator);

    log.info("Hello, {s}!", .{"world"});
    try expectEqualStrings("info: Hello, world!\n", writer.buffered());
    writer.end = 0;

    log.scoped(.my_scope).warn("", .{});
    try expectEqualStrings("warning(my_scope): \n", writer.buffered());
    writer.end = 0;

    log.scoped(.other_scope).err("`{s}` not found: {t}", .{ "test.txt", error.FileNotFound });
    try expectEqualStrings("error(other_scope): `test.txt` not found: FileNotFound\n", writer.buffered());
}

test "log with complex config" {
    const expectEqualStrings = std.testing.expectEqualStrings;
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const log = Axe(.{
        .format = "[%l]%s: %m", // no newline
        .scope_format = " %% %",
        .loc_format = "", // can't test because it's inconsistent
        .time_format = .disabled, // can't test because it's inconsistent
        .styles = .{
            .err = &.{ .bold, .red },
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
        .quiet = true,
        .mutex = .default,
    });
    try log.init(std.testing.allocator, &.{&writer}, null);
    defer log.deinit(std.testing.allocator);

    log.info("Hello, {s}!", .{"world"});
    try expectEqualStrings("[" ++ Style.fmt(&.{.blue}, "INFO") ++ "]: Hello, world!", writer.buffered());
    writer.end = 0;

    log.scoped(.my_scope).warn("", .{});
    try expectEqualStrings("[" ++ Style.fmt(&.{.yellow}, "WARNING") ++ "] % my_scope: ", writer.buffered());
    writer.end = 0;

    log.scoped(.other_scope).err("`{s}` not found: {t}", .{ "test.txt", error.FileNotFound });
    try expectEqualStrings(
        "[" ++ Style.fmt(&.{ .bold, .red }, "ERROR") ++ "] % other_scope: `test.txt` not found: FileNotFound",
        writer.buffered(),
    );
}

test "json log" {
    const expectEqualStrings = std.testing.expectEqualStrings;
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const log = Axe(.{
        .format =
        \\{"level":"%l",%s"data":%m}
        \\
        ,
        .scope_format =
        \\"scope":"%",
        ,
        .quiet = true,
        .color = .never,
    });
    try log.init(std.testing.allocator, &.{&writer}, null);
    defer log.deinit(std.testing.allocator);

    log.debug("\"json log\"", .{});
    try expectEqualStrings(
        \\{"level":"debug","data":"json log"}
        \\
    , writer.buffered());
    writer.end = 0;

    log.scoped(.main).info("\"json scoped\"", .{});
    try expectEqualStrings(
        \\{"level":"info","scope":"main","data":"json scoped"}
        \\
    , writer.buffered());
    writer.end = 0;

    const data = .{ .a = 42, .b = 3.14 };
    log.info("{f}", .{std.json.fmt(data, .{})});
    try expectEqualStrings(
        \\{"level":"info","data":{"a":42,"b":3.14}}
        \\
    , writer.buffered());
}
