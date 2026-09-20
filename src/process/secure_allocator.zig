const std = @import("std");

const Allocator = std.mem.Allocator;

/// An allocator facade that clears every allocation immediately before freeing it.
///
/// Resize and remap are intentionally unsupported so old storage always passes
/// through the clearing `free` callback instead of being released implicitly.
pub const SecureAllocator = struct {
    /// Allocator that supplies and ultimately releases the storage.
    backing: Allocator,

    /// Returns the allocator interface tied to this facade's lifetime.
    ///
    /// All allocations must be freed before the `SecureAllocator` value goes out
    /// of scope because the returned interface borrows `self` as its context.
    pub fn allocator(self: *SecureAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *SecureAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawAlloc(len, alignment, return_address);
    }

    fn resize(
        _: *anyopaque,
        _: []u8,
        _: std.mem.Alignment,
        _: usize,
        _: usize,
    ) bool {
        return false;
    }

    fn remap(
        _: *anyopaque,
        _: []u8,
        _: std.mem.Alignment,
        _: usize,
        _: usize,
    ) ?[*]u8 {
        return null;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *SecureAllocator = @ptrCast(@alignCast(context));
        std.crypto.secureZero(u8, memory);
        self.backing.rawFree(memory, alignment, return_address);
    }
};

/// Clears an owned mutable byte slice and then frees it with `gpa`.
pub fn secureFree(gpa: Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    gpa.free(bytes);
}
