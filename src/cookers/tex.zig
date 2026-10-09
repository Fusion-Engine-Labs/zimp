const std = @import("std");

const Zatex = @import("../formats/ztex.zig").Zatex;
const RawTexture = @import("../assets/raw/texture.zig").RawTexture;
const CookedTexture = @import("../assets/cooked/texture.zig").CookedTexture;

const Cooker = @import("cooker.zig").Cooker;
const CookInput = @import("cooker.zig").CookInput;

pub fn cooker() Cooker {
    return .{ .cook_fn = cookTexture };
}

fn cookTexture(input: *const CookInput) !void {
    const temporary_allocator = input.temporary_allocator orelse input.allocator;
    const raw = try RawTexture.init(input.source.path, @constCast(input.bytes));
    defer raw.deinit(temporary_allocator);

    var cooked = try CookedTexture.cook(temporary_allocator, &raw, input.target_profile);
    defer cooked.deinit(temporary_allocator);

    try Zatex.write(input.writer, cooked);
}
