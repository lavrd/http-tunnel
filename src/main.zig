const std = @import("std");
const builtin = @import("builtin");
const time = @cImport(@cInclude("time.h"));

// Init scoped logger.
const log = std.log.scoped(.main);

// Init our custom logger handler.
pub const std_options = .{
    .log_level = .debug,
    .logFn = logFn,
};

var wait_signal = true;
var wait_signal_mutex = std.Thread.Mutex{};
var wait_signal_cond = std.Thread.Condition{};

fn handleSignal(
    signal: i32,
    _: *const std.posix.siginfo_t,
    _: ?*anyopaque,
) callconv(.C) void {
    log.debug("os signal received: {d}", .{signal});
    wait_signal_mutex.lock();
    defer wait_signal_mutex.unlock();
    wait_signal = false;
    wait_signal_cond.broadcast();
}

pub fn main() !void {
    switch (builtin.os.tag) {
        .macos, .linux => {},
        else => {
            log.err(
                "at the moment software is not working on any system except macOS or Linux",
                .{},
            );
            return;
        },
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        .thread_safe = true,
        .verbose_log = true,
    }){};
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const http_server_thread = try std.Thread.spawn(.{}, httpServer, .{
        @as(std.mem.Allocator, allocator),
        @as(u16, 14600),
    });

    var act = std.posix.Sigaction{
        .handler = .{ .sigaction = handleSignal },
        .mask = std.posix.empty_sigset,
        .flags = (std.posix.SA.SIGINFO),
    };
    var oact: std.posix.Sigaction = undefined;
    try std.posix.sigaction(std.posix.SIG.INT, &act, &oact);
    waitSignalLoop();

    // Waiting for other threads to be stopped.
    http_server_thread.join();

    log.info("successfully exiting...", .{});
}

fn waitSignalLoop() void {
    log.info("starting to wait for os signal", .{});
    _ = shouldWait(0);
    log.info("exiting os signal waiting loop", .{});
}

fn httpServer(allocator: std.mem.Allocator, port: u16) !void {
    const address = std.net.Address.parseIp("0.0.0.0", port) catch unreachable;
    var tcp_server = try address.listen(.{
        .reuse_address = false,
        .force_nonblocking = true,
    });
    defer tcp_server.deinit();
    log.info("starting http server on {any}", .{address});

    while (shouldWait(5)) {
        const response = tcp_server.accept() catch |err| {
            switch (err) {
                error.WouldBlock => continue,
                else => return,
            }
        };
        var read_buffer: [1024]u8 = [_]u8{0} ** 1024;
        var http_server = std.http.Server.init(response, &read_buffer);
        switch (http_server.state) {
            .ready => {},
            else => continue,
        }
        var request = try http_server.receiveHead();

        for (request.head.target) |byte| {
            if (!std.ascii.isASCII(byte)) {
                log.err("request target is no ascii: {any}", .{request.head.target});
                continue;
            }
        }
        const target = try std.ascii.allocLowerString(allocator, request.head.target);
        log.debug("http request {s} {s}", .{
            @tagName(request.head.method),
            target,
        });
        allocator.free(target);

        try request.respond(&[_]u8{}, .{
            .status = std.http.Status.ok,
        });
    }

    log.info("http server was stopped by os signal", .{});
}

fn shouldWait(ms: u64) bool {
    wait_signal_mutex.lock();
    defer wait_signal_mutex.unlock();
    if (ms == 0) {
        wait_signal_cond.wait(&wait_signal_mutex);
    } else {
        wait_signal_cond.timedWait(
            &wait_signal_mutex,
            ms * std.time.ns_per_ms,
        ) catch |err| switch (err) {
            error.Timeout => {},
        };
    }
    return wait_signal;
}

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    const stderr = std.io.getStdErr().writer();

    var buf: [20]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();
    const time_str: []u8 = allocator.alloc(u8, buf.len) catch {
        nosuspend stderr.print(
            "failed to allocate memory to convert timestamp to string\n",
            .{},
        ) catch return;
        return;
    };
    defer allocator.free(time_str);

    const timestamp = time.time(null);
    if (timestamp == -1) {
        nosuspend stderr.print(
            "failed to retrieve current time from time.h\n",
            .{},
        ) catch return;
        return;
    }
    const tm_info = time.localtime(&timestamp);
    const n = time.strftime(
        time_str[0..buf.len],
        buf.len,
        "%Y-%m-%d %H:%M:%S",
        tm_info,
    );
    // We need to compare with buf length - 1 because returning length
    // doesn't contain terminating null character.
    if (n != buf.len - 1) {
        nosuspend stderr.print(
            "failed to format current timestamp using time.h: {d}\n",
            .{n},
        ) catch return;
        return;
    }

    const scoped_level = comptime switch (scope) {
        .gpa => std.log.Level.debug,
        else => level,
    };
    nosuspend stderr.print(
        "{s} " ++ "[" ++ comptime scoped_level.asText() ++ "] " ++ "(" ++ @tagName(scope) ++ ") " ++ format ++ "\n",
        .{time_str} ++ args,
    ) catch return;
}
