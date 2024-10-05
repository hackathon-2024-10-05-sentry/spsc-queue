const std = @import("std");

pub fn SPSCQueue(comptime T: type) type {
    const Self = @This();

    // Assume a cache line size of 64 bytes for alignment to prevent false sharing.
    const kCacheLineSize: usize = 64;

    return struct {
        allocator: *std.mem.Allocator, // Memory allocator for dynamic memory management.
        capacity: usize, // Total capacity of the queue.
        slots: []Slot, // Array of slots containing data and sequence numbers.

        // Producer index: tracks the next slot the producer will write to.
        producer_index: usize = 0,

        // Consumer index: tracks the next slot the consumer will read from.
        consumer_index: usize = 0,

        // Definition of a slot in the queue.
        const Slot = struct {
            data: T, // The actual data stored in the slot.

            // Sequence number used for synchronization between producer and consumer.
            seq: std.atomic.AtomicUsize align(kCacheLineSize) = std.atomic.AtomicUsize{ .value = 0 },

            // Padding to ensure the entire slot is aligned to the cache line size.
            // This prevents false sharing by ensuring that each slot occupies its own cache line.
            padding: [kCacheLineSize - (@sizeOf(T) % kCacheLineSize) - @sizeOf(std.atomic.AtomicUsize)]u8 = undefined,
        };

        /// Initializes the queue with the given capacity and allocator.
        /// Allocates memory for the slots and initializes sequence numbers.
        pub fn init(self: *Self, allocator: *std.mem.Allocator, requested_capacity: usize) !void {
            // Ensure the capacity is at least 1 to avoid zero-capacity queues.
            const adjusted_capacity = if (requested_capacity < 1) 1 else requested_capacity;

            self.capacity = adjusted_capacity;
            self.allocator = allocator;

            // Allocate memory for the slots array.
            self.slots = try allocator.alloc(Slot, self.capacity);

            // Initialize the sequence numbers for each slot.
            // This sets up the initial state where all slots are considered empty.
            var idx: usize = 0;
            for (self.slots) |*slot| {
                // Initialize sequence number to the slot index.
                slot.seq.store(idx, std.atomic.Order.Relaxed);
                idx += 1;
            }
        }

        /// Deinitializes the queue and frees allocated memory.
        /// Cleans up any remaining elements if the element type T has a deinit method.
        pub fn deinit(self: *Self) void {
            // If T has a deinit method, call it for any remaining elements in the queue.
            if (@hasDecl(T, "deinit")) {
                while (self.try_pop()) |value| {
                    value.deinit();
                } else |err| {
                    if (err != error.QueueEmpty) {
                        @panic("Unexpected error during deinit");
                    }
                }
            }
            // Free the allocated memory for the slots.
            self.allocator.free(self.slots);
        }

        /// Attempts to insert an element into the queue.
        /// Returns an error if the queue is full.
        pub fn try_push(self: *Self, value: T) !void {
            // Get the current producer index.
            const idx = self.producer_index;

            // Calculate the slot to write to based on the producer index.
            var slot = &self.slots[idx % self.capacity];

            // Load the sequence number of the slot.
            const seq = slot.seq.load(std.atomic.Order.Acquire);

            // Calculate the difference between the sequence number and the expected value.
            const dif = isize(seq) - isize(idx);

            if (dif == 0) {
                // The slot is available for writing.

                // Write the data to the slot.
                slot.data = value;

                // Update the sequence number to indicate the slot is now full.
                slot.seq.store(idx + 1, std.atomic.Order.Release);

                // Advance the producer index.
                self.producer_index = idx + 1;
            } else if (dif < 0) {
                // The slot is not available; the queue is full.
                return error.QueueFull;
            } else {
                // Should not happen; indicates a logic error.
                unreachable;
            }
        }

        /// Inserts an element into the queue, blocking if the queue is full.
        /// This method will wait until space becomes available.
        pub fn push(self: *Self, value: T) void {
            while (true) {
                // Attempt to push the value into the queue.
                const err = self.try_push(value);

                if (err) |e| {
                    // An error occurred.
                    if (e == error.QueueFull) {
                        // Queue is full; yield to allow other threads to progress.
                        std.thread.yield();
                    } else {
                        // Unexpected error; should not happen.
                        unreachable;
                    }
                } else {
                    // Success; exit the loop.
                    return;
                }
            }
        }

        /// Attempts to remove and return an element from the queue.
        /// Returns an error if the queue is empty.
        pub fn try_pop(self: *Self) !T {
            // Get the current consumer index.
            const idx = self.consumer_index;

            // Calculate the slot to read from based on the consumer index.
            var slot = &self.slots[idx % self.capacity];

            // Load the sequence number of the slot.
            const seq = slot.seq.load(std.atomic.Order.Acquire);

            // Calculate the difference between the sequence number and the expected value.
            const dif = isize(seq) - (isize(idx) + 1);

            if (dif == 0) {
                // The slot is ready to be read.

                // Read the data from the slot.
                const value = slot.data;

                // Update the sequence number to indicate the slot is now empty.
                slot.seq.store(idx + self.capacity, std.atomic.Order.Release);

                // Advance the consumer index.
                self.consumer_index = idx + 1;

                // Return the retrieved value.
                return value;
            } else if (dif < 0) {
                // The slot is not ready; the queue is empty.
                return error.QueueEmpty;
            } else {
                // Should not happen; indicates a logic error.
                unreachable;
            }
        }

        /// Removes and returns an element from the queue, blocking if the queue is empty.
        /// This method will wait until an element becomes available.
        pub fn pop(self: *Self) !T {
            while (true) {
                // Attempt to pop a value from the queue.
                if (self.try_pop()) |value| {
                    // Success; return the value.
                    return value;
                } else |err| {
                    if (err == error.QueueEmpty) {
                        // Queue is empty; yield to allow other threads to progress.
                        std.thread.yield();
                    } else {
                        // Unexpected error; should not happen.
                        unreachable;
                    }
                }
            }
        }

        /// Checks if the queue is empty.
        /// Returns true if the queue has no elements.
        pub fn empty(self: *Self) bool {
            // The queue is empty if the producer and consumer indices are equal.
            return self.size() == 0;
        }

        /// Returns the number of elements currently in the queue.
        pub fn size(self: *Self) usize {
            // Calculate the size by subtracting the consumer index from the producer index.
            return self.producer_index - self.consumer_index;
        }

        /// Returns the capacity of the queue.
        /// This is the total number of elements the queue can hold.
        pub fn capacity(self: *Self) usize {
            return self.capacity;
        }
    };
}
