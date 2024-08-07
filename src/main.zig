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

const Side = enum {
    Client,
    Server,
};

const Config = struct {
    side: Side,
};

const HTTPRequest = struct {
    Method: std.http.Method,
    Path: []const u8,
};

const HTTPResponse = struct {
    Status: std.http.Status,
};

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

fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        _raw: ?T,
        _mutex: std.Thread.Mutex,
        _cond: std.Thread.Condition,

        fn Init(value: ?T) Self {
            return .{
                ._raw = value,
                ._mutex = .{},
                ._cond = .{},
            };
        }

        fn send(self: *Self, data: T) void {
            self._mutex.lock();
            defer self._mutex.unlock();
            self._raw = data;
            self._cond.signal();
        }

        fn try_receive(
            self: *Self,
        ) ?T {
            self._mutex.lock();
            defer self._mutex.unlock();
            return self._change();
        }

        fn receive(self: *Self) ?T {
            self._mutex.lock();
            defer self._mutex.unlock();
            self._cond.wait(&self._mutex);
            return self._change();
        }

        fn close(self: *Self) void {
            self._mutex.lock();
            defer self._mutex.unlock();
            // Currently channel works like that:
            // - If someone wait using "receive" function
            // - And cond wakes up
            // - And value in null
            // - It means channel is closed.
            self._raw = null;
            self._cond.signal();
        }

        fn _change(self: *Self) ?T {
            if (self._raw) |raw| {
                self._raw = null;
                return raw;
            }
            return null;
        }
    };
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

    const config = try parseConfig(allocator);
    log.info("starting as a {any}", .{config});

    var req_ch = Channel(HTTPRequest).Init(null);
    var res_ch = Channel(HTTPResponse).Init(null);

    var http_server_thread: ?std.Thread = null;
    var tcp_server_thread: ?std.Thread = null;
    switch (config.side) {
        Side.Client => {},
        Side.Server => {
            http_server_thread = try std.Thread.spawn(.{}, httpServer, .{
                @as(std.mem.Allocator, allocator),
                @as(u16, 14600),
                @as(*Channel(HTTPRequest), &req_ch),
                @as(*Channel(HTTPResponse), &res_ch),
            });
            tcp_server_thread = try std.Thread.spawn(.{}, tcpServer, .{
                @as(std.mem.Allocator, allocator),
                @as(u16, 22000),
                @as(*Channel(HTTPRequest), &req_ch),
                @as(*Channel(HTTPResponse), &res_ch),
            });
        },
    }

    var act = std.posix.Sigaction{
        .handler = .{ .sigaction = handleSignal },
        .mask = std.posix.empty_sigset,
        .flags = (std.posix.SA.SIGINFO),
    };
    var oact: std.posix.Sigaction = undefined;
    try std.posix.sigaction(std.posix.SIG.INT, &act, &oact);
    waitSignalLoop();

    // Waiting for other threads to be stopped.
    if (http_server_thread) |thread| thread.join();
    if (tcp_server_thread) |thread| thread.join();

    log.info("successfully exiting...", .{});
}

fn waitSignalLoop() void {
    log.info("starting to wait for os signal", .{});
    _ = shouldWait(0);
    log.info("exiting os signal waiting loop", .{});
}

fn httpServer(
    allocator: std.mem.Allocator,
    port: u16,
    req_ch: *Channel(HTTPRequest),
    res_ch: *Channel(HTTPResponse),
) !void {
    const address = std.net.Address.parseIp("0.0.0.0", port) catch unreachable;
    var tcp_server = try address.listen(.{
        .reuse_address = true,
        .force_nonblocking = true,
    });
    defer tcp_server.deinit();
    log.info("starting http server on {any}", .{address});

    while (shouldWait(5)) {
        const conn = tcp_server.accept() catch |err| {
            switch (err) {
                error.WouldBlock => continue,
                else => return,
            }
        };
        var buffer: [1024]u8 = [_]u8{0} ** 1024;
        var http_server = std.http.Server.init(conn, &buffer);
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

        // todo: is it possible to write to closed channel here?
        req_ch.send(HTTPRequest{
            .Method = request.head.method,
            .Path = request.head.target,
        });
        const response = res_ch.receive();
        if (response) |res| {
            try request.respond(&[_]u8{}, .{
                .status = res.Status,
            });
            continue;
        }
        // It means channels were closed;
        break;
    }

    log.info("http server was stopped by os signal", .{});
}

fn tcpServer(
    allocator: std.mem.Allocator,
    port: u16,
    req_ch: *Channel(HTTPRequest),
    res_ch: *Channel(HTTPResponse),
) !void {
    const address = std.net.Address.parseIp("0.0.0.0", port) catch unreachable;
    var tcp_server = try address.listen(.{
        .reuse_address = true,
        .force_nonblocking = true,
    });
    defer tcp_server.deinit();
    log.info("starting tcp server on {any}", .{address});

    main: while (shouldWait(5)) {
        var conn: std.net.Server.Connection = undefined;
        while (shouldWait(5)) {
            conn = tcp_server.accept() catch |err| {
                switch (err) {
                    error.WouldBlock => continue,
                    else => return,
                }
            };
            break;
        } else {
            log.info("tcp server was stopped by os signal", .{});
            return;
        }
        defer conn.stream.close();
        log.info("new connection is established", .{});

        const request = req_ch.receive();
        if (request) |req| {
            var json = std.ArrayList(u8).init(allocator);
            try std.json.stringify(req, .{}, json.writer());
            _ = try conn.stream.writeAll(json.items);

            var buffer: [1024]u8 = [_]u8{0} ** 1024;
            while (shouldWait(5)) {
                const n = conn.stream.read(&buffer) catch |err| {
                    switch (err) {
                        error.WouldBlock => continue,
                        else => return,
                    }
                };
                if (n == 0) {
                    log.info("tcp connection closed", .{});
                    continue :main;
                }
                res_ch.send(HTTPResponse{
                    .Status = std.http.Status.teapot,
                });
            }
        }
        // It means channels were closed.
        break;
    }

    log.info("tcp server was stopped by os signal", .{});
}

fn connectToServer() !void {
    const address = try std.net.Address.parseIp4("172.0.0.2", 22000);
    const conn = try std.net.tcpConnectToAddress(address);
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

fn parseConfig(allocator: std.mem.Allocator) !Config {
    var args = try std.process.ArgIterator.initWithAllocator(allocator);
    defer args.deinit();
    // Skip executable
    _ = args.next();
    if (args.next()) |arg| {
        const config = try std.json.parseFromSlice(
            Config,
            allocator,
            arg,
            .{},
        );
        defer config.deinit();
        return config.value;
    }
    return error.NoArgWithConfig;
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
