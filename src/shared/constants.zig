/// Four-byte file magics. Cooked asset magics are the first field of `wire.FileHeader`.
pub const FORMAT_MAGIC = struct {
    pub const ZMESH = "ZMSH";
    pub const ZACHE = "ZCHE";
    pub const ZATEX = "ZTEX";
    pub const ZSHDR = "ZSHD";
    pub const ZAMAT = "ZMAT";
};
