const std = @import("std");
const bench = @import("bench");
const maolonglong_spsc_queue = @import("maolonglong/spsc_queue");

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try bw.flush(); // don't forget to flush!
}

test "benchmark maolong" {
    try bench.benchmark(struct {
        const numitems = 100_000;

        pub const min_iterations = 100;

        pub fn spscQueue() !usize {
            const Q = maolonglong_spsc_queue.SPSCQueue(i32);

            const Closure = struct {
                const Self = @This();

                read_count: usize = 0,
                write_done: bool = false,
                q: Q,

                fn producer(self: *Self) !void {
                    for (0..numitems) |_| {
                        while (!self.q.push(1)) {
                            try std.Thread.yield();
                        }
                    }
                    @atomicStore(bool, &self.write_done, true, .seq_cst);
                }

                fn consumer(self: *Self) !void {
                    while (!@atomicLoad(bool, &self.write_done, .seq_cst)) {
                        if (self.q.pop() != null) {
                            self.read_count += 1;
                        } else {
                            try std.Thread.yield();
                        }
                    }
                    while (self.q.pop() != null) {
                        self.read_count += 1;
                    }
                }
            };

            var c = Closure{
                .q = try Q.init(std.testing.allocator, 1024),
            };
            defer c.q.deinit();

            const thread = try std.Thread.spawn(.{}, Closure.producer, .{&c});
            try c.consumer();
            thread.join();

            try std.testing.expectEqual(numitems, c.read_count);
            return c.read_count;
        }

        pub fn arraylist() !usize {
            const Q = std.ArrayList(i32);

            const Closure = struct {
                const Self = @This();

                read_count: usize = 0,
                write_done: bool = false,
                q: Q,
                mu: std.Thread.Mutex = .{},

                fn producer(self: *Self) !void {
                    for (0..numitems) |_| {
                        self.mu.lock();
                        try self.q.append(1);
                        self.mu.unlock();
                    }
                    @atomicStore(bool, &self.write_done, true, .seq_cst);
                }

                fn consumer(self: *Self) !void {
                    while (!@atomicLoad(bool, &self.write_done, .seq_cst)) {
                        self.mu.lock();
                        const ret = self.q.popOrNull();
                        self.mu.unlock();
                        if (ret == null) {
                            try std.Thread.yield();
                        } else {
                            self.read_count += 1;
                        }
                    }
                    while (self.q.items.len > 0) {
                        _ = self.q.pop();
                        self.read_count += 1;
                    }
                }
            };

            var c = Closure{
                .q = Q.init(std.testing.allocator),
            };
            defer c.q.deinit();

            const thread = try std.Thread.spawn(.{}, Closure.producer, .{&c});
            try c.consumer();
            thread.join();

            try std.testing.expectEqual(numitems, c.read_count);
            return c.read_count;
        }
    });
}
