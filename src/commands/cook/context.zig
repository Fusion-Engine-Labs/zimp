const std = @import("std");
const ProjectId = @import("../../id/id_types.zig").ProjectId;

/// Present when cooking a project (`zimp cook --project <root>`): after the
/// cook, the pipeline builds `assets.zmanifest`
/// sidecars. Directory-mode cooks (`--source/--output`) leave this null and
/// produce no manifest.
pub const ProjectCookInfo = struct {
    project_id: ProjectId,
    /// Project root; `manifest_path` is relative to it. Not owned.
    root_dir: std.Io.Dir,
    /// e.g. ".fusion/assets.zmanifest" (from the project manifest).
    manifest_path: []const u8,
};

pub const CookContext = struct {
    io: std.Io,
    source: std.Io.Dir,
    output: std.Io.Dir,
    output_path: []const u8,
    force: bool,
    project: ?ProjectCookInfo = null,

    /// Namespace for `AssetId`s embedded in cooked references. Directory-mode
    /// cooks have no project and produce no manifest, so they use the zero
    /// project id: the embedded ids only need to be deterministic.
    pub fn projectId(self: *const CookContext) ProjectId {
        return if (self.project) |project| project.project_id else .zero;
    }
};
