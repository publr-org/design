//! The WASM build's allocator. Small blocks come from the standard WASM allocator; blocks
//! of 64 KiB and more are runs of whole WASM pages, taken first-fit from a list of free
//! runs that merges neighbours, and grown at the end of memory when none fits.
//!
//! WASM memory never shrinks, so what matters is the peak. The standard allocator rounds
//! a large block up to a power of two and reuses freed blocks only for the same size, so
//! a 22 MB image takes 32 MB and the scratch of every size ever used stays reserved. Here
//! a block takes the pages it needs and freed pages serve any later size.

const std = @import("std");

const page = std.wasm.page_size;
/// Blocks this large or larger are page runs.
const large = page;
const small = std.heap.wasm_allocator;

/// A free run of pages: [start, start + count).
const Run = struct {
    start: usize,
    count: usize,
};

/// Free runs in address order. A full list drops the smallest run (never seen in use).
var runs: [4096]Run = undefined;
var run_count: usize = 0;

/// Bytes handed out and not given back (large blocks counted in whole pages): what an
/// engine holds, unlike the memory's size, which never shrinks.
pub var live: usize = 0;

pub const allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    },
};

fn pagesFor(len: usize) usize {
    return (len + page - 1) / page;
}

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    if (len < large) {
        const p = small.rawAlloc(len, alignment, ra);
        if (p != null) live += len;
        return p;
    }
    _ = ctx;
    const n = pagesFor(len);
    live += n * page;
    for (runs[0..run_count], 0..) |*r, i| {
        if (r.count < n) continue;
        const start = r.start;
        r.start += n;
        r.count -= n;
        if (r.count == 0) removeRun(i);
        return @ptrFromInt(start * page);
    }
    const prev = @wasmMemoryGrow(0, n);
    if (prev < 0) {
        live -= n * page;
        return null;
    }
    return @ptrFromInt(@as(usize, @intCast(prev)) * page);
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
    // A block stays on the side it was made on.
    if (memory.len < large) {
        if (new_len >= large or !small.rawResize(memory, alignment, new_len, ra)) return false;
        live = live + new_len - memory.len;
        return true;
    }
    _ = ctx;
    if (new_len < large) return false;
    const start = @intFromPtr(memory.ptr) / page;
    const have = pagesFor(memory.len);
    const want = pagesFor(new_len);
    if (want == have) return true;
    if (want < have) {
        addRun(start + want, have - want);
        live -= (have - want) * page;
        return true;
    }
    // Grow into a free run right after the block.
    for (runs[0..run_count], 0..) |*r, i| {
        if (r.start != start + have) continue;
        const extra = want - have;
        if (r.count < extra) return false;
        r.start += extra;
        r.count -= extra;
        if (r.count == 0) removeRun(i);
        live += extra * page;
        return true;
    }
    return false;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
    if (resize(ctx, memory, alignment, new_len, ra)) return memory.ptr;
    return null;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
    if (memory.len < large) {
        live -= memory.len;
        return small.rawFree(memory, alignment, ra);
    }
    _ = ctx;
    live -= pagesFor(memory.len) * page;
    addRun(@intFromPtr(memory.ptr) / page, pagesFor(memory.len));
}

fn removeRun(i: usize) void {
    std.mem.copyForwards(Run, runs[i .. run_count - 1], runs[i + 1 .. run_count]);
    run_count -= 1;
}

/// Puts a run back in address order, merged with the runs it touches.
fn addRun(start: usize, count: usize) void {
    var i: usize = 0;
    while (i < run_count and runs[i].start < start) i += 1;
    const joins_prev = i > 0 and runs[i - 1].start + runs[i - 1].count == start;
    const joins_next = i < run_count and start + count == runs[i].start;
    if (joins_prev and joins_next) {
        runs[i - 1].count += count + runs[i].count;
        removeRun(i);
    } else if (joins_prev) {
        runs[i - 1].count += count;
    } else if (joins_next) {
        runs[i].start = start;
        runs[i].count += count;
    } else {
        if (run_count == runs.len) {
            // Out of room: forget the smallest run (its pages stay unused).
            var min: usize = 0;
            for (runs[0..run_count], 0..) |r, k| {
                if (r.count < runs[min].count) min = k;
            }
            if (runs[min].count >= count) return;
            removeRun(min);
            if (min < i) i -= 1;
        }
        std.mem.copyBackwards(Run, runs[i + 1 .. run_count + 1], runs[i..run_count]);
        runs[i] = .{
            .start = start,
            .count = count,
        };
        run_count += 1;
    }
}
