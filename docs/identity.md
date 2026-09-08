# Asset identity

Project cooks assign an `AssetId` to every successfully cooked asset.

An asset ID is deterministically derived from:

1. The `project_id` stored in `.fusion/fusion.proj`.
2. The asset's normalized source path relative to the project's `assets_dir`.

Authored and generated assets use the same rule. Asset content, timestamps,
incremental-cache state, and cooked output are not identity inputs.

As a result:

- Editing or replacing an asset's contents preserves its ID.
- Deleting `.zcache`, cooked output, or `assets.zmanifest` preserves IDs.
- Copying an asset to a different path produces a different ID.
- Moving or renaming an asset changes its ID.
- Changing the project ID changes every project asset ID.

`assets.zmanifest` is generated output, sorted by source path, and should not
be committed. Project-mode cooking recreates it deterministically. Directory
mode does not produce asset identity or a manifest.

Until an asset-move command is available, renames must also update every
persisted `AssetId` reference and every authored path reference that targets
the moved asset.
