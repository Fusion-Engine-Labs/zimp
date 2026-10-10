/// Four-byte file magics. Cooked asset magics are the first field of
/// `wire.FileHeader`; `ZPAK` starts a pack (`formats/zpak.zig`) and `ZSCN` a
/// cooked scene (`scene/binary_codec.zig`).
pub const FORMAT_MAGIC = struct {
    pub const ZMESH = "ZMSH";
    pub const ZACHE = "ZCHE";
    pub const ZATEX = "ZTEX";
    pub const ZSHDR = "ZSHD";
    pub const ZAMAT = "ZMAT";
    pub const ZSCN = "ZSCN";
    pub const ZPAK = "ZPAK";
};
