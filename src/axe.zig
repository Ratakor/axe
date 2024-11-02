const std = @import("std");
const builtin = @import("builtin");
const Chameleon = @import("chameleon").ComptimeChameleon;
const zeit = @import("zeit");

pub const Config = struct {
    /// The format to use for the log messages.
    /// The following specifiers are supported:
    /// - `%l`: The log level text.
    /// - `%s`: The scope text, format is specified with `scope_format`.
    /// - `%t`: The time, format is specified with `time`.
    /// - `%f`: The actual format string.
    /// - `%%`: A literal `%`.
    format: []const u8 = "%l%s: %f\n",
    /// The format to use for the scope text.
    /// The following specifiers are supported:
    /// - `%`: The scope name.
    /// - `%%`: A literal `%`.
    scope_format: []const u8 = "(%)",
    /// Whether to enable color output.
    color: enum {
        /// Check for NO_COLOR, CLICOLOR_FORCE and tty support on File.
        /// Color output is disabled on other writers.
        /// This is the same as `always` on the comptime interface.
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
    /// The mutex interface to use for the log messages.
    /// default and custom are not supported on the comptime interface.
    mutex: union(enum) {
        none,
        default,
        custom: type,
        global: struct {
            lock: fn () void,
            unlock: fn () void,
        },
    } = .none,
};

const default_writers = [_]std.io.AnyWriter{
    std.io.getStdErr().writer().any(),
};

/// Create a new comptime logger based on the given configuration.
/// Logging with time is not supported on the comptime interface because it requires allocation.
/// Windows colors are not supported on the comptime interface because it requires storing an handle.
pub fn Comptime(comptime config: Config) type {
    if (config.time != .disabled) {
        @compileError("Time is not supported on the comptime interface, use Runtime instead.");
    }
    switch (config.mutex) {
        .none, .global => {},
        .default, .custom => @compileError("Use `global` mutex for comptime logging."),
    }

    return struct {
        fn dummy() void {}
        const lock = switch (config.mutex) {
            .none => dummy,
            .global => |g| g.lock,
            else => unreachable,
        };
        const unlock = switch (config.mutex) {
            .none => dummy,
            .global => |g| g.unlock,
            else => unreachable,
        };

        /// The list of writers to write the log messages to.
        pub const writers = config.writers;

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
        ///     .logFn = axe.Comptime(.{}).standardLog,
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

            lock();
            defer unlock();

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
                                'l' => fmt = fmt ++ levelAsText(config, level, switch (config.color) {
                                    .auto, .always => .escape_codes,
                                    .never => .no_color,
                                }),
                                's' => fmt = fmt ++ parseScopeFormat(config.scope_format, scope),
                                'f' => fmt = fmt ++ format,
                                't' => @compileError("Time specifier is not supported on the comptime interface."),
                                '%' => fmt = fmt ++ "%",
                                else => @compileError("Unknown format specifier after `%`: `" ++ &[_]u8{config.format[i]} ++ "`."),
                            }
                        },
                        '{' => fmt = fmt ++ "{{",
                        '}' => fmt = fmt ++ "}}",
                        else => fmt = fmt ++ &[_]u8{config.format[i]},
                    }
                }
                return fmt;
            }
        }
    };
}

/// Create a new runtime logger based on the given configuration.
/// Runtime known writers are provided through the `init` function instead of `config`.
pub fn Runtime(comptime config: Config) type {
    if (config.time == .strftime) comptime {
        var bogus: zeit.Time = .{};
        const void_writer: std.io.GenericWriter(void, error{}, struct {
            pub fn write(_: void, bytes: []const u8) error{}!usize {
                return bytes.len;
            }
        }.write) = .{ .context = {} };
        bogus.strftime(void_writer, config.time.strftime) catch |e|
            @compileError("Invalid strftime format: " ++ @errorName(e));
    };

    return struct {
        const Self = @This();

        timezone: if (config.time != .disabled) zeit.TimeZone else void,
        writers: []const std.io.AnyWriter,
        files: []const File,
        mutex: if (MutexType) |T| *T else void,

        const MutexType: ?type = switch (config.mutex) {
            .none, .global => null,
            .default => if (builtin.single_threaded) null else std.Thread.Mutex,
            .custom => |T| T,
        };

        const File = struct {
            handle: std.fs.File,
            config: std.io.tty.Config, // TODO: takes more space than necessary
        };

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
                .timezone = self.timezone,
                .writers = self.writers,
                .files = self.files,
                .mutex = self.mutex,
            };
        }

        /// Instantiate a new logger.
        /// If `outputs` is supplied it will be used instead of the writers provided through `config`.
        /// `outputs` can be a tuple, an array, a writer or a struct with a writer method.
        /// If one of the `outputs` is a file then NO_COLOR, CLICOLOR_FORCE and
        ///   tty support will be checked if `config.color` is set to `.auto`.
        /// `env` is used to check `TZ` and `TZDIR` for the timezone.
        /// `env` is only used during initialization and is not stored.
        pub fn init(
            allocator: std.mem.Allocator,
            outputs: anytype,
            env: ?*const std.process.EnvMap,
        ) !Self {
            var logger: Self = .{
                .timezone = if (config.time != .disabled) try zeit.local(allocator, env) else {},
                .writers = undefined,
                .files = undefined,
                .mutex = if (MutexType) |T| mx: {
                    const mutex = try allocator.create(T);
                    mutex.* = .{};
                    break :mx mutex;
                } else {},
            };
            try logger.parseOutputs(allocator, outputs);
            return logger;
        }

        /// Deinitialize the logger.
        /// Must not be called on logger instance that were not created with `init`.
        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            if (config.time != .disabled) {
                self.timezone.deinit();
            }
            if (MutexType != null) {
                allocator.destroy(self.mutex);
            }
            allocator.free(self.writers);
            allocator.free(self.files);
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

            switch (config.mutex) {
                .none => {},
                .global => |g| g.lock(),
                .default => if (!builtin.single_threaded) self.mutex.lock(),
                .custom => self.mutex.lock(),
            }
            defer switch (config.mutex) {
                .none => {},
                .global => |g| g.unlock(),
                .default => if (!builtin.single_threaded) self.mutex.unlock(),
                .custom => self.mutex.unlock(),
            };

            const time = if (config.time != .disabled) t: {
                const now = zeit.instant(.{ .timezone = &self.timezone }) catch unreachable;
                break :t now.time();
            } else {};

            nosuspend {
                if (config.buffering) {
                    for (self.writers) |writer| {
                        var bw = std.io.bufferedWriter(writer);
                        Self.print(bw.writer(), .no_color, time, message_level, format, args);
                        bw.flush() catch return;
                    }
                    for (self.files) |file| {
                        var bw = std.io.bufferedWriter(file.handle.writer().any());
                        Self.print(bw.writer(), file.config, time, message_level, format, args);
                        bw.flush() catch return;
                    }
                } else {
                    for (self.writers) |writer| {
                        Self.print(writer, .no_color, time, message_level, format, args);
                    }
                    for (self.files) |file| {
                        Self.print(file.handle.writer(), file.config, time, message_level, format, args);
                    }
                }
            }
        }

        inline fn print(
            writer: anytype,
            tty_config: std.io.tty.Config,
            time: if (config.time != .disabled) zeit.Time else void,
            comptime level: Level,
            comptime format: []const u8,
            args: anytype,
        ) void {
            comptime var i: usize = 0;
            inline while (true) {
                const prev = i;
                i = comptime std.mem.indexOfScalarPos(u8, config.format, i, '%') orelse break;
                writer.writeAll(config.format[prev..i]) catch return;
                i += 1; // skip '%'
                if (i >= config.format.len) {
                    @compileError("Missing format specifier after `%`.");
                }
                switch (config.format[i]) {
                    'l' => writer.writeAll(levelAsText(config, level, tty_config)) catch return,
                    's' => writer.writeAll(comptime parseScopeFormat(config.scope_format, config.scope)) catch return,
                    't' => switch (config.time) {
                        .disabled => @compileError("Time specifier without time format."),
                        .gofmt => |gofmt| time.gofmt(writer, gofmt.fmt) catch return,
                        .strftime => |fmt| time.strftime(writer, fmt) catch return,
                    },
                    'f' => writer.print(format, args) catch return,
                    '%' => writer.writeAll("%") catch return,
                    else => @compileError("Unknown format specifier after `%`: `" ++ &[_]u8{config.format[i]} ++ "`."),
                }
                i += 1; // skip format specifier
            }
            if (i < config.format.len) {
                writer.writeAll(config.format[i..]) catch return;
            }
        }

        inline fn parseOutputs(
            self: *Self,
            allocator: std.mem.Allocator,
            outputs: anytype,
        ) std.mem.Allocator.Error!void {
            var writers = std.ArrayList(std.io.AnyWriter).init(allocator);
            defer writers.deinit();

            var files = std.ArrayList(File).init(allocator);
            defer files.deinit();

            const T = @TypeOf(outputs);
            switch (@typeInfo(T)) {
                .pointer => |ti| {
                    if (ti.size == .One) {
                        const tic = @typeInfo(ti.child);
                        if (tic == .@"struct" and tic.@"struct".is_tuple) {
                            // support for &.{} syntax
                            inline for (tic.@"struct".fields) |field| {
                                try writers.append(toAnyWriter(@field(outputs.*, field.name)));
                            }
                        }
                    } else {
                        @compileError("Unsupported outputs type: " ++ @typeName(T));
                    }
                },
                .array => @compileError("TODO: array"),
                .@"struct" => |ti| {
                    if (ti.is_tuple) {
                        inline for (ti.fields) |field| {
                            if (field.type == std.fs.File) {
                                const file = @field(outputs, field.name);
                                try files.append(.{ .handle = file, .config = std.io.tty.detectConfig(file) });
                            } else {
                                try writers.append(toAnyWriter(@field(outputs, field.name)));
                            }
                        }
                    } else {
                        if (T == std.fs.File) {
                            const file = outputs;
                            try files.append(.{ .handle = file, .config = std.io.tty.detectConfig(file) });
                        } else {
                            try writers.append(toAnyWriter(outputs));
                        }
                    }
                },
                .void, .undefined, .null => {},
                .optional => @compileError("TODO: optional"),
                else => @compileError("Unsupported outputs type: " ++ @typeName(T)),
            }

            if (writers.items.len == 0 and files.items.len == 0) {
                self.writers = try allocator.dupe(std.io.AnyWriter, config.writers);
            } else {
                self.writers = try writers.toOwnedSlice();
            }
            self.files = try files.toOwnedSlice();
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

fn levelAsText(
    comptime config: Config,
    comptime level: Level,
    colors: std.io.tty.Config,
) []const u8 {
    switch (colors) {
        .no_color => return comptime @field(config.level_text, @tagName(level)),
        .escape_codes => {
            comptime var chameleon: Chameleon = .{};
            comptime for (@field(config.styles, @tagName(level))) |style| {
                Style.apply(&chameleon, style);
            };
            return comptime chameleon.fmt(@field(config.level_text, @tagName(level)));
        },
        .windows_api => |ctx| {
            _ = ctx;
            unreachable; // TODO: need to apply attributes, write text, then reset attributes
        },
    }
}

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

inline fn genericToAnyWriter(writer: anytype) std.io.AnyWriter {
    const T = @TypeOf(writer);
    if (std.meta.hasMethod(T, "any") and @hasField(T, "context")) {
        // check if context is a pointer to prevent from General Protection Exception
        // >.any() uses &stream.context which would be a pointer to a pointer to the actual context
        // >the pointer to the actual context will be undefined once quitting this function
        // >causing a General Protection Exception when using the produced AnyWriter
        if (@typeInfo(@TypeOf(writer.context)) == .pointer) {
            @compileError("Found `GenericWriter` with pointer context: use .any() to convert it to AnyWriter.");
        }
        return writer.any();
    } else {
        @compileError("Unsupported output type: " ++ @typeName(T));
    }
}

inline fn toAnyWriter(stream: anytype) std.io.AnyWriter {
    const T = @TypeOf(stream);
    if (T == std.io.AnyWriter) {
        return stream;
    } else if (std.meta.hasMethod(T, "writer")) {
        // std.fs.File, std.ArrayList, std.BoundedArray, ...
        const writer = stream.writer();
        if (@TypeOf(writer) == std.io.AnyWriter) {
            return writer;
        } else {
            // probably a std.io.GenericWriter
            return genericToAnyWriter(writer);
        }
    } else {
        return genericToAnyWriter(stream);
    }
}

test "runtime log without styles" {
    const expectEqualStrings = std.testing.expectEqualStrings;
    var empty_env = std.process.EnvMap.init(std.testing.allocator);
    defer empty_env.deinit();
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();

    const log = try Runtime(.{
        .styles = .none,
        .buffering = false,
    }).init(std.testing.allocator, .{list.writer().any()}, &empty_env); // tuple with std.io.AnyWriter
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

test "runtime log with NO_COLOR=1" {
    const expectEqualStrings = std.testing.expectEqualStrings;
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("NO_COLOR", "1");
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();

    const log = try Runtime(.{
        .buffering = false,
    }).init(std.testing.allocator, &.{list.writer().any()}, &env); // pointer to tuple with std.io.AnyWriter
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

test "runtime log with complex config & NO_COLOR unset" {
    const expectEqualStrings = std.testing.expectEqualStrings;
    var empty_env = std.process.EnvMap.init(std.testing.allocator);
    defer empty_env.deinit();
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    comptime var chameleon: Chameleon = .{};

    const log = try Runtime(.{
        .format = "[%l]%s: %f", // no newline
        .scope_format = " %% %",
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
        .buffering = false,
        .time = .disabled, // can't test because it's inconsistent
        .mutex = .default,
    }).init(std.testing.allocator, list.writer().any(), &empty_env);
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

test "runtime json log" {
    const expectEqualStrings = std.testing.expectEqualStrings;
    var empty_env = std.process.EnvMap.init(std.testing.allocator);
    defer empty_env.deinit();
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();

    const log = try Runtime(.{
        .format =
        \\{"level":"%l",%s"data":%f}
        \\
        ,
        .scope_format =
        \\"scope":"%",
        ,
        .styles = .none,
        .buffering = false,
    }).init(std.testing.allocator, list.writer().any(), &empty_env); // std.io.AnyWriter
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
