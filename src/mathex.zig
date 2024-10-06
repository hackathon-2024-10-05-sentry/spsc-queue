const std = @import("std");

pub fn isPowerOfTwo(comptime n: anytype) bool {
    if (n == 0) return false; // 0 is not a power of two
    return (n & (n - 1)) == 0;
}

pub fn intln2(comptime n: anytype) @TypeOf(n) {
    return std.math.ln2(n);
}
