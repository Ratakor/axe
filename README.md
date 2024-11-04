# Axe 🪓

A fully customizable, drop-in replacement for `std.Options.LogFn` with support
for multiple file logging, buffering, JSON, time, custom format, colors
(automatic tty detection, windows support, NO\_COLOR support, CLICOLOR\_FORCE
support), source location, and thread safety (multiple mutex interface available)!

![](screenshot.png)

## Usage

Add it to an existing project with this command:
```sh
zig fetch --save git+https://github.com/Ratakor/axe
```
Then add the module your build.zig.
```zig
const axe = b.dependency("axe", .{}).module("axe");
exe.root_module.addImport("axe", axe);
```

Check [example.zig](example/example.zig) for how to use it!

## TODO
- Replace stdout/stderr with files?
- Add a way to combine multiple loggers into one.
