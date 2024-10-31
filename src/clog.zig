const std = @import("std");
const Chameleon = @import("chameleon");
const zeit = @import("zeit");

pub const Config = struct {
    /// The format to use for the log messages.
    /// The following specifiers are supported:
    /// - `%l`: The log level text.
    /// - `%s`: The scope text, format is specified with `scope_format`.
    /// - `%t`: The time, format is specified with `time`.
    /// - `%f`: The actual format string.
    /// - `%%`: A literal `%`.
    format: []const u8 = "%l%s: %f",
    /// The format to use for the scope text.
    /// The following specifiers are supported:
    /// - `%`: The scope name.
    /// - `%%`: A literal `%`.
    scope_format: []const u8 = "(%)",
    /// Set to `.none` to disable all styles.
    styles: Styles = .{},
    /// The text to display for each log level.
    level_text: LevelText = .{},
    /// The scope to use for the log messages. Ignored for `std.log`.
    scope: @Type(.enum_literal) = .default,
    /// A comptime list of writers to write the log messages to.
    /// See `Runtime.init` for runtime writers.
    writers: []const std.io.AnyWriter = &default_writers,
    /// Whether to buffer the log messages before writing them.
    buffering: bool = true,
    /// The time format to use for the log messages.
    /// Not supported on the comptime interface.
    time: union(enum) {
        disabled,
        /// Format based on golang time package.
        gofmt: GoTimeFormat,
        /// Format based on strftime(3).
        strftime: []const u8,
    } = .disabled,
};

const default_writers = [_]std.io.AnyWriter{
    std.io.getStdErr().writer().any(),
};

/// Create a new comptime logger based on the given configuration.
/// Logging with time is not supported on the comptime interface because it requires allocation.
pub fn Comptime(comptime config: Config) type {
    if (config.time != .disabled) {
        @compileError("Time is not supported on the comptime interface, use Runtime instead.");
    }

    return struct {
        /// Returns a scoped logging namespace that logs all messages using the scope
        /// provided here.
        pub fn scoped(comptime scope: @Type(.enum_literal)) type {
            var new_config = config;
            new_config.scope = scope;
            return Comptime(new_config);
        }

        /// Log an error message. This log level is intended to be used
        /// when something has gone wrong. This might be recoverable or might
        /// be followed by the program exiting.
        pub fn err(comptime format: []const u8, args: anytype) void {
            standardLog(.err, config.scope, format, args);
        }

        /// Log a warning message. This log level is intended to be used if
        /// it is uncertain whether something has gone wrong or not, but the
        /// circumstances would be worth investigating.
        pub fn warn(comptime format: []const u8, args: anytype) void {
            standardLog(.warn, config.scope, format, args);
        }

        /// Log an info message. This log level is intended to be used for
        /// general messages about the state of the program.
        pub fn info(comptime format: []const u8, args: anytype) void {
            standardLog(.info, config.scope, format, args);
        }

        /// Log a debug message. This log level is intended to be used for
        /// messages which are only useful for debugging.
        pub fn debug(comptime format: []const u8, args: anytype) void {
            standardLog(.debug, config.scope, format, args);
        }

        /// Drop-in replacement for `std.log.defaultLog`.
        /// The scope given in `config` will be ignored by the standard log functions.
        /// ```zig
        /// pub const std_options: std.Options = .{
        ///     .logFn = clog.Comptime(.{}).standardLog,
        /// };
        /// ```
        pub fn standardLog(
            comptime message_level: Level,
            comptime scope: @Type(.enum_literal),
            comptime format: []const u8,
            args: anytype,
        ) void {
            if (comptime !std.log.logEnabled(message_level, config.scope)) {
                return;
            }
            const actual_format = comptime parseFormat(message_level, scope, format);

            nosuspend {
                if (config.buffering) {
                    inline for (config.writers) |writer| {
                        var bw = std.io.bufferedWriter(writer);
                        bw.writer().print(actual_format, args) catch return;
                        bw.flush() catch return;
                    }
                } else {
                    inline for (config.writers) |writer| {
                        writer.print(actual_format, args) catch return;
                    }
                }
            }
        }

        fn parseFormat(
            comptime level: Level,
            comptime scope: @Type(.enum_literal),
            comptime format: []const u8,
        ) []const u8 {
            comptime {
                var fmt: []const u8 = "";
                var i: usize = 0;
                while (i < config.format.len) : (i += 1) {
                    switch (config.format[i]) {
                        '%' => {
                            i += 1;
                            if (i >= config.format.len) {
                                @compileError("Missing format specifier after `%`.");
                            }
                            switch (config.format[i]) {
                                'l' => fmt = fmt ++ levelAsText(level),
                                's' => fmt = fmt ++ parseScopeFormat(config.scope_format, scope),
                                'f' => fmt = fmt ++ format,
                                't' => @compileError("Time specifier is not supported on the comptime interface."),
                                '%' => fmt = fmt ++ "%",
                                else => @compileError("Unknown format specifier after `%`: `" ++ &[_]u8{config.format[i]} ++ "`."),
                            }
                        },
                        else => fmt = fmt ++ &[_]u8{config.format[i]},
                    }
                }
                return fmt ++ "\n";
            }
        }

        fn levelAsText(comptime level: Level) []const u8 {
            comptime {
                var chameleon = Chameleon.initComptime();
                for (@field(config.styles, @tagName(level))) |style| {
                    Style.apply(&chameleon, style);
                }
                return chameleon.fmt(@field(config.level_text, @tagName(level)));
            }
        }
    };
}

/// Create a new runtime logger based on the given configuration.
/// Runtime known writers are provided through the `init` function instead of `config`.
pub fn Runtime(comptime config: Config) type {
    comptime {
        if (config.time == .strftime) {
            var bogus: zeit.Time = .{};
            const void_writer: std.io.GenericWriter(void, error{}, struct {
                pub fn write(_: void, bytes: []const u8) error{}!usize {
                    return bytes.len;
                }
            }.write) = .{ .context = {} };
            bogus.strftime(void_writer, config.time.strftime) catch |e|
                @compileError("Invalid strftime format: " ++ @errorName(e));
        }
    }

    return struct {
        const Self = @This();

        color_enabled: bool,
        timezone: if (config.time == .disabled) void else zeit.TimeZone,
        writers: []const std.io.AnyWriter,

        /// Create a new logger with a different scope.
        /// The result must not live longer than the parent.
        /// The result must not be deinitialized.
        // I think it's better to not make a dupe of the parent to keep the same interface as Comptime.
        // It's also more efficient and convenient.
        pub fn scoped(self: Self, comptime scope: @Type(.enum_literal)) T: {
            var new_config = config;
            new_config.scope = scope;
            break :T Runtime(new_config);
        } {
            return .{
                .color_enabled = self.color_enabled,
                .timezone = self.timezone,
                .writers = self.writers,
            };
        }

        /// Instantiate a new logger.
        /// If `writers` is not `null` it will be used instead of the writers provided through `config`.
        pub fn init(
            allocator: std.mem.Allocator,
            writers: ?[]const std.io.AnyWriter,
            env_map: ?*const std.process.EnvMap,
        ) !Self {
            if (env_map) |env| {
                return initWithEnv(allocator, writers, env);
            } else {
                var env = try std.process.getEnvMap(allocator);
                defer env.deinit();
                return initWithEnv(allocator, writers, &env);
            }
        }

        fn initWithEnv(
            allocator: std.mem.Allocator,
            writers: ?[]const std.io.AnyWriter,
            env_map: *const std.process.EnvMap,
        ) !Self {
            const no_color = env_map.get("NO_COLOR");
            return .{
                .color_enabled = no_color == null or no_color.?.len == 0,
                .timezone = if (config.time == .disabled) {} else try zeit.local(allocator, env_map),
                .writers = try allocator.dupe(std.io.AnyWriter, writers orelse config.writers),
            };
        }

        /// Deinitialize the logger.
        /// Must not be called on logger instance that were not created with `init`.
        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            if (config.time != .disabled) {
                self.timezone.deinit();
            }
            allocator.free(self.writers);
        }

        /// Log an error message. This log level is intended to be used
        /// when something has gone wrong. This might be recoverable or might
        /// be followed by the program exiting.
        pub fn err(self: Self, comptime format: []const u8, args: anytype) void {
            self.innerLog(.err, format, args);
        }

        /// Log a warning message. This log level is intended to be used if
        /// it is uncertain whether something has gone wrong or not, but the
        /// circumstances would be worth investigating.
        pub fn warn(self: Self, comptime format: []const u8, args: anytype) void {
            self.innerLog(.warn, format, args);
        }

        /// Log an info message. This log level is intended to be used for
        /// general messages about the state of the program.
        pub fn info(self: Self, comptime format: []const u8, args: anytype) void {
            self.innerLog(.info, format, args);
        }

        /// Log a debug message. This log level is intended to be used for
        /// messages which are only useful for debugging.
        pub fn debug(self: Self, comptime format: []const u8, args: anytype) void {
            self.innerLog(.debug, format, args);
        }

        fn innerLog(
            self: Self,
            comptime message_level: Level,
            comptime format: []const u8,
            args: anytype,
        ) void {
            if (comptime !std.log.defaultLogEnabled(message_level)) {
                return;
            }

            const time = if (config.time == .disabled) {} else t: {
                const now = zeit.instant(.{ .timezone = &self.timezone }) catch unreachable;
                break :t now.time();
            };

            nosuspend {
                if (config.buffering) {
                    for (self.writers) |writer| {
                        var bw = std.io.bufferedWriter(writer);
                        self.print(bw.writer(), time, message_level, format, args);
                        bw.flush() catch return;
                    }
                } else {
                    for (self.writers) |writer| {
                        self.print(writer, time, message_level, format, args);
                    }
                }
            }
        }

        inline fn print(
            self: Self,
            writer: anytype,
            time: if (config.time == .disabled) void else zeit.Time,
            comptime level: Level,
            comptime format: []const u8,
            args: anytype,
        ) void {
            comptime var i: usize = 0;
            inline while (i < config.format.len) : (i += 1) {
                switch (config.format[i]) {
                    '%' => {
                        i += 1;
                        if (i >= config.format.len) {
                            @compileError("Missing format specifier after `%`.");
                        }
                        switch (config.format[i]) {
                            'l' => writer.writeAll(levelAsText(level, self.color_enabled)) catch return,
                            's' => writer.writeAll(comptime parseScopeFormat(config.scope_format, config.scope)) catch return,
                            't' => switch (config.time) {
                                .disabled => {},
                                .gofmt => |gofmt| time.gofmt(writer, gofmt.fmt) catch return,
                                .strftime => |fmt| time.strftime(writer, fmt) catch return,
                            },
                            'f' => writer.print(format, args) catch return,
                            '%' => writer.writeAll("%") catch return,
                            else => @compileError("Unknown format specifier after `%`: `" ++ &[_]u8{config.format[i]} ++ "`."),
                        }
                    },
                    else => writer.writeByte(config.format[i]) catch return,
                }
            }
            writer.writeAll("\n") catch return;
        }

        fn levelAsText(comptime level: Level, color_enabled: bool) []const u8 {
            if (!color_enabled) {
                return comptime @field(config.level_text, @tagName(level));
            }
            comptime var chameleon = Chameleon.initComptime();
            comptime for (@field(config.styles, @tagName(level))) |style| {
                Style.apply(&chameleon, style);
            };
            return comptime chameleon.fmt(@field(config.level_text, @tagName(level)));
        }
    };
}

pub const Style = union(enum) {
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
    black_bright,
    gray,
    grey,
    red_bright,
    green_bright,
    yellow_bright,
    blue_bright,
    magenta_bright,
    cyan_bright,
    white_bright,
    bg_black,
    bg_red,
    bg_green,
    bg_yellow,
    bg_blue,
    bg_magenta,
    bg_cyan,
    bg_white,
    bg_black_bright,
    bg_gray,
    bg_grey,
    bg_red_bright,
    bg_green_bright,
    bg_yellow_bright,
    bg_blue_bright,
    bg_magenta_bright,
    bg_cyan_bright,
    bg_white_bright,
    rgb: struct { r: u8, g: u8, b: u8 },
    bg_rgb: struct { r: u8, g: u8, b: u8 },
    hex: []const u8,
    bg_hex: []const u8,

    fn apply(chameleon: anytype, style: Style) void {
        _ = switch (style) {
            .double_underline => chameleon.addStyle("doubleUnderline"),
            .black_bright => chameleon.addStyle("blackBright"),
            .red_bright => chameleon.addStyle("redBright"),
            .green_bright => chameleon.addStyle("greenBright"),
            .yellow_bright => chameleon.addStyle("yellowBright"),
            .blue_bright => chameleon.addStyle("blueBright"),
            .magenta_bright => chameleon.addStyle("magentaBright"),
            .cyan_bright => chameleon.addStyle("cyanBright"),
            .white_bright => chameleon.addStyle("whiteBright"),
            .bg_black => chameleon.addStyle("bgBlack"),
            .bg_red => chameleon.addStyle("bgRed"),
            .bg_green => chameleon.addStyle("bgGreen"),
            .bg_yellow => chameleon.addStyle("bgYellow"),
            .bg_blue => chameleon.addStyle("bgBlue"),
            .bg_magenta => chameleon.addStyle("bgMagenta"),
            .bg_cyan => chameleon.addStyle("bgCyan"),
            .bg_white => chameleon.addStyle("bgWhite"),
            .bg_black_bright => chameleon.addStyle("bgBlackBright"),
            .bg_red_bright => chameleon.addStyle("bgRedBright"),
            .bg_green_bright => chameleon.addStyle("bgGreenBright"),
            .bg_yellow_bright => chameleon.addStyle("bgYellowBright"),
            .bg_blue_bright => chameleon.addStyle("bgBlueBright"),
            .bg_magenta_bright => chameleon.addStyle("bgMagentaBright"),
            .bg_cyan_bright => chameleon.addStyle("bgCyanBright"),
            .bg_white_bright => chameleon.addStyle("bgWhiteBright"),
            .rgb => |rgb| chameleon.rgb(rgb.r, rgb.g, rgb.b),
            .bg_rgb => |rgb| chameleon.bgRgb(rgb.r, rgb.g, rgb.b),
            .hex => |hex| chameleon.hex(hex),
            .bg_hex => |hex| chameleon.bgHex(hex),
            else => chameleon.addStyle(@tagName(style)),
        };
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

fn parseScopeFormat(comptime format: []const u8, comptime scope: @Type(.enum_literal)) []const u8 {
    comptime {
        if (scope == .default) {
            return "";
        }

        var fmt: []const u8 = "";
        var i: usize = 0;
        while (i < format.len) : (i += 1) {
            switch (format[i]) {
                '%' => if (i + 1 >= format.len or format[i + 1] != '%') {
                    fmt = fmt ++ @tagName(scope);
                } else {
                    fmt = fmt ++ "%";
                    i += 1;
                },
                else => fmt = fmt ++ &[_]u8{format[i]},
            }
        }
        return fmt;
    }
}
