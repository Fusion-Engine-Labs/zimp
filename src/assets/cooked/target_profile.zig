const std = @import("std");
const builtin = @import("builtin");

/// Graphics capability set that cooked assets are encoded for. It is a cook
/// option (`zimp cook --profile`, or `target_profile` in `fusion.proj`), not a
/// property of the machine running the cooker, so any host can cook for any
/// target. Values are stored in `.zcache`; keep them stable.
pub const TargetProfile = enum(u8) {
    /// OpenGL 4.1 (macOS). No BPTC: color uses S3TC (BC1/BC3), HDR uses
    /// RGB9_E5. RGTC (BC4/BC5) is core since GL 3.0.
    gl41 = 0,
    /// GL 4.2+ and Vulkan-class desktop GPUs: BPTC (BC7/BC6H) and RGTC.
    desktop = 1,

    /// Profile used when neither the command line nor the project names one:
    /// the one the current host's runtime can load.
    pub fn host() TargetProfile {
        return if (builtin.os.tag == .macos) .gl41 else .desktop;
    }

    pub fn parse(name: []const u8) ?TargetProfile {
        return std.meta.stringToEnum(TargetProfile, name);
    }
};

test "TargetProfile.parse accepts tag names only" {
    try std.testing.expectEqual(TargetProfile.gl41, TargetProfile.parse("gl41").?);
    try std.testing.expectEqual(TargetProfile.desktop, TargetProfile.parse("desktop").?);
    try std.testing.expectEqual(@as(?TargetProfile, null), TargetProfile.parse("GL41"));
}
