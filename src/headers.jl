
"""
    iszipsignature_h(highbytes)

Check if the 2 bytes given are a valid second half of a 4-byte ZIP header
signature.
"""
function iszipsignature_h(highbytes::UInt16)
    return highbytes in (
        SIG_LOCAL_FILE_H,
        SIG_EXTRA_DATA_H,
        SIG_CENTRAL_DIRECTORY_H,
        SIG_DIGITAL_SIGNATURE_H,
        SIG_END_OF_CENTRAL_DIRECTORY_H,
        SIG_ZIP64_CENTRAL_DIRECTORY_LOCATOR_H.SIG_ZIP64_END_OF_CENTRAL_DIRECTORY_H,
    )
end
