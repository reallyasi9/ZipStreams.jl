@enum Signature::UInt32 begin
    LocalFileHeaderSignature = 0x04034b50
    ExtraDataRecordSignature = 0x08064b50
    CentralDirectorySignature = 0x02014b50
    # DigitalSignatureSignature = 0x05054b50 # Forbidden by ISO/IEC 21320-1
    EndCentralDirectorySignature = 0x06054b50
    Zip64EndCentralLocatorSignature = 0x07064b50
    Zip64EndCentralDirectorySignature = 0x06064b50
end

const ZIP_VERSION = 45

@enum GeneralPurposeFlag::UInt16 begin
    # Encrypted = 0x0001 # Forbidden by ISO/IEC 21320-1
    CompressionOptionsFlags = 0x0006
    LocalHeaderSignatureEmptyFlag = 0x0008
    # PatchedData = 0x0020 # Forbidden by ISO/IEC 21320-1
    # StrongEncryption = 0x0040 # Forbidden by ISO/IEC 21320-1
    LanguageEncodingFlag = 0x0800
    # LocalHeaderMasked = 0x2000 # Forbidden by ISO/IEC 21320-1
end

# Forbidden by ISO/IEC 21320-1
# @enum ImplodeOption::UInt16 begin
#     Window8K = 0x0002
#     ShannonFano3Trees = 0x0004
# end

@enum DeflateOption::UInt16 begin
    DeflateNormal = 0x0000
    DeflateMaximum = 0x0002
    DeflateFast = 0x0004
    DeflateSuperFast = 0x0006
end

# Forbidden by ISO/IEC 21320-1
# @enum LZMAOption::UInt16 begin
#     LZMAEOS = 0x0002
# end

@enum CompressionMethod::UInt16 begin
    StoreCompression = 0
    # Shrink = 1 # Forbidden by ISO/IEC 21320-1
    # Reduce1 = 2 # Forbidden by ISO/IEC 21320-1
    # Reduce2 = 3 # Forbidden by ISO/IEC 21320-1
    # Reduce3 = 4 # Forbidden by ISO/IEC 21320-1
    # Reduce4 = 5 # Forbidden by ISO/IEC 21320-1
    # Implode = 6 # Forbidden by ISO/IEC 21320-1
    DeflateCompression = 8
    # Deflate64 = 9 # Forbidden by ISO/IEC 21320-1
    # OldTERSE = 10 # Forbidden by ISO/IEC 21320-1
    # BZIP2 = 12 # Forbidden by ISO/IEC 21320-1
    # LZMA = 14 # Forbidden by ISO/IEC 21320-1
    # CMPSC = 16 # Forbidden by ISO/IEC 21320-1
    # NewTERSE = 18 # Forbidden by ISO/IEC 21320-1
    # LZ77 = 19 # Forbidden by ISO/IEC 21320-1
    # Zstd = 93 # Forbidden by ISO/IEC 21320-1
    # MP3 = 94 # Forbidden by ISO/IEC 21320-1
    # XZ = 95 # Forbidden by ISO/IEC 21320-1
    # JPEG = 96 # Forbidden by ISO/IEC 21320-1
    # WavPack = 97 # Forbidden by ISO/IEC 21320-1
    # PPMd = 98 # Forbidden by ISO/IEC 21320-1
    # AEx = 99 # Forbidden by ISO/IEC 21320-1
end

@enum ExtraHeaderID::UInt16 begin
    Zip64Header = 0x0001
    # AVInfoHeader = 0x0007
    # OS2Header = 0x0009
    # NTFSHeader = 0x000a
    # OpenVMSHeader = 0x000c
    # UNIXHeader = 0x000d
    # PatchDescriptor = 0x000f # Forbidden by ISO/IEC 21320-1
    # CertificateStore = 0x0014 # Forbidden by ISO/IEC 21320-1
    # CentralDirectoryCertificateID = 0x0016 # Forbidden by ISO/IEC 21320-1
    # StrongEncryptionHeader = 0x0017 # Forbidden by ISO/IEC 21320-1
    # RecordManagementControls = 0x0018 # Forbidden by ISO/IEC 21320-1
    # RecipientCertificateList = 0x0019 # Forbidden by ISO/IEC 21320-1
    # PolicyDecryptionKey = 0x0021 # Forbidden by ISO/IEC 21320-1
    # SmartcryptKeyProvider = 0x0022 # Forbidden by ISO/IEC 21320-1
    # SmartcryptPolicyKeyData = 0x0023 # Forbidden by ISO/IEC 21320-1
    # S390_AS400 = 0x0065 # Forbidden by ISO/IEC 21320-1
end