const std = @import("std");
const assert = std.debug.assert;

pub fn SPSCQueue(comptime T: type) type {
    const Self = @This();

    // Assume a cache line size of 64 bytes
    // const kCacheLineSize = 64;
    const kCacheLineSize: usize = 64;
    // Calculate padding to prevent false sharing
    const kPadding = ((kCacheLineSize - 1) / @sizeOf(T)) + 1;

    return struct {
        allocator: *std.mem.Allocator,
        capacity: usize,
        slots: []T,

        // Atomic write index, aligned to cache line size
        writeIdx: std.atomic.AtomicUsize align(kCacheLineSize) = std.atomic.AtomicUsize{ .value = 0 },
        // Cache variable to reduce memory traffic
        readIdxCache: usize = 0,

        // Padding to prevent false sharing between writeIdx and readIdx
        writePadding: [kCacheLineSize - (@sizeOf(std.atomic.AtomicUsize) % kCacheLineSize)]u8 = undefined,

        // Atomic read index, aligned to cache line size
        readIdx: std.atomic.AtomicUsize align(kCacheLineSize) = std.atomic.AtomicUsize{ .value = 0 },
        // Cache variable to reduce memory traffic
        writeIdxCache: usize = 0,

        // Padding to prevent false sharing between readIdx and other variables
        readPadding: [kCacheLineSize - (@sizeOf(std.atomic.AtomicUsize) % kCacheLineSize)]u8 = undefined,

        /// Initializes the queue with the given capacity and allocator.
        pub fn init(self: *Self, allocator: *std.mem.Allocator, requested_capacity: usize) !void {
            // Ensure capacity is at least 1
            var adjusted_capacity = if (requested_capacity < 1) 1 else requested_capacity;
            adjusted_capacity += 1; // Add slack element

            const max = std.math.maxInt(u64);

            // Prevent overflowing usize
            const max_capacity = usize(max) - 2 * kPadding;
            if (adjusted_capacity > max_capacity) {
                adjusted_capacity = max_capacity;
            }

            self.capacity = adjusted_capacity;
            self.allocator = allocator;

            // Allocate slots with padding to prevent false sharing
            const total_slots = adjusted_capacity + 2 * kPadding;
            self.slots = try allocator.alloc(T, total_slots);
        }

        /// Deinitializes the queue and frees allocated memory.
        pub fn deinit(self: *Self) void {
            // Clean up any remaining elements
            while (self.front() != null) {
                self.pop();
            }
            self.allocator.free(self.slots);
        }

        /// Inserts an element into the queue. Blocks if the queue is full.
        pub fn emplace(self: *Self, value: T) void {
            const writeIdx = self.writeIdx.load(std.atomic.Order.Relaxed);
            const nextWriteIdx = self.incrementIndex(writeIdx);
            while (nextWriteIdx == self.readIdxCache) {
                self.readIdxCache = self.readIdx.load(std.atomic.Order.Acquire);
            }
            // Place the element in the padded slots array
            self.slots[writeIdx + kPadding] = value;
            self.writeIdx.store(nextWriteIdx, std.atomic.Order.Release);
        }

        /// Attempts to insert an element into the queue without blocking.
        pub fn try_emplace(self: *Self, value: T) bool {
            const writeIdx = self.writeIdx.load(std.atomic.Order.Relaxed);
            const nextWriteIdx = self.incrementIndex(writeIdx);
            if (nextWriteIdx == self.readIdxCache) {
                self.readIdxCache = self.readIdx.load(std.atomic.Order.Acquire);
                if (nextWriteIdx == self.readIdxCache) {
                    return false;
                }
            }
            self.slots[writeIdx + kPadding] = value;
            self.writeIdx.store(nextWriteIdx, std.atomic.Order.Release);
            return true;
        }

        /// Inserts an element by copying it.
        pub fn push(self: *Self, value: T) void {
            self.emplace(value);
        }

        /// Attempts to insert an element by copying without blocking.
        pub fn try_push(self: *Self, value: T) bool {
            return self.try_emplace(value);
        }

        /// Retrieves a pointer to the front element without removing it.
        pub fn front(self: *Self) ?*const T {
            const readIdx = self.readIdx.load(std.atomic.Order.Relaxed);
            if (readIdx == self.writeIdxCache) {
                self.writeIdxCache = self.writeIdx.load(std.atomic.Order.Acquire);
                if (self.writeIdxCache == readIdx) {
                    return null;
                }
            }
            return &self.slots[readIdx + kPadding];
        }

        /// Removes the front element from the queue.
        pub fn pop(self: *Self) void {
            const readIdx = self.readIdx.load(std.atomic.Order.Relaxed);
            assert(self.writeIdx.load(std.atomic.Order.Acquire) != readIdx);
            // Call deinit if T has one
            if (@hasDecl(T, "deinit")) {
                self.slots[readIdx + kPadding].deinit();
            }
            const nextReadIdx = self.incrementIndex(readIdx);
            self.readIdx.store(nextReadIdx, std.atomic.Order.Release);
        }

        /// Returns the number of elements in the queue.
        pub fn size(self: *Self) usize {
            const write = self.writeIdx.load(std.atomic.Order.Acquire);
            const read = self.readIdx.load(std.atomic.Order.Acquire);
            return self.calculateSize(write, read);
        }

        /// Checks if the queue is empty.
        pub fn empty(self: *Self) bool {
            return self.writeIdx.load(std.atomic.Order.Acquire) ==
                self.readIdx.load(std.atomic.Order.Acquire);
        }

        /// Returns the capacity of the queue.
        pub fn capacity(self: *Self) usize {
            return self.capacity - 1;
        }

        /// Increments an index, wrapping around if necessary.
        fn incrementIndex(self: *Self, idx: usize) usize {
            var next = idx + 1;
            if (next == self.capacity) {
                next = 0;
            }
            return next;
        }

        /// Calculates the size based on write and read indices.
        fn calculateSize(self: *Self, write: usize, read: usize) usize {
            if (write >= read) {
                return write - read;
            } else {
                return (self.capacity - read) + write;
            }
        }
    };
}
