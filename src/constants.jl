@enum Signature::UInt32 begin
    LocalFileHeaderSignature = 0x04034b50
    ExtraDataRecordSignature = 0x08064b50
    CentralDirectorySignature = 0x02014b50
    DigitalSignatureSignature = 0x05054b50
    EndCentralDirectorySignature = 0x06054b50
    Zip64EndCentralLocatorSignature = 0x07064b50
    Zip64EndCentralDirectorySignature = 0x06064b50
end

const ZIP_VERSION = 20

@enum GeneralPurposeFlag::UInt16 begin
    Encrypted = 0x0001
    CompressionOptions = 0x0006
    LocalHeaderSignatureEmpty = 0x0008
    PatchedData = 0x0020
    StrongEncryption = 0x0040
    LanguageEncoding = 0x0800
    LocalHeaderMasked = 0x2000
end

@enum ImplodeOption::UInt16 begin
    Window8K = 0x0002
    ShannonFano3Trees = 0x0004
end

@enum DeflateOption::UInt16 begin
    Normal = 0x0000
    Maximum = 0x0002
    Fast = 0x0004
    SuperFast = 0x0006
end

@enum LZMAOption::UInt16 begin
    LZMAEOS = 0x0002
end

@enum CompressionMethod::UInt16 begin
    Store = 0
    Shrink = 1
    Reduce1 = 2
    Reduce2 = 3
    Reduce3 = 4
    Reduce4 = 5
    Implode = 6
    Deflate = 8
    Deflate64 = 9
    OldTERSE = 10
    BZIP2 = 12
    LZMA = 14
    CMPSC = 16
    NewTERSE = 18
    LZ77 = 19
    Zstd = 93
    MP3 = 94
    XZ = 95
    JPEG = 96
    WavPack = 97
    PPMd = 98
    AEx = 99
end

@enum ExtraHeaderID::UInt16 begin
    Zip64 = 0x0001
    AVInfo = 0x0007
    OS2 = 0x0009
    NTFS = 0x000a
    OpenVMS = 0x000c
    UNIX = 0x000d
    PatchDescriptor = 0x000f
    CertificateStore = 0x0014
    CentralDirectoryCertificateID = 0x0016
    StrongEncryptionHeader = 0x0017
    RecordManagementControls = 0x0018
    RecipientCertificateList = 0x0019
    PolicyDecryptionKey = 0x0021
    SmartcryptKeyProvider = 0x0022
    SmartcryptPolicyKeyData = 0x0023
    S390_AS400 = 0x0065
end