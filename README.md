# Clog

A fully customizable, drop-in replacement for `std.Options.LogFn` with support
for multiple file logging, buffering, colors (NO_COLOR supported) and time!

![](screenshot.png)

## Usage

Add it to an existing project with this command:
```sh
zig fetch --save git+https://github.com/Ratakor/clog
```
Then add the module your build.zig.
```zig
const clog = b.dependency("clog", .{}).module("clog");
exe.root_module.addImport("clog", clog);
```

Check [example.zig](example/example.zig) for how to use it!

# TODO
- support windows colors
