import Foundation
import XCTest
@testable import SynthKit

/// Small real archives, so the unpackers are tested against bytes a real
/// `xz` and a real `zip` produced rather than against ones this suite wrote.
///
/// Base64 rather than committed binaries: two files of a few hundred bytes
/// each, inline where the test that uses them can be read beside them, and
/// with no build-phase resource copying to keep working. The catalog's actual
/// 412 MB and 205 MB archives are exercised in the manual smoke run, which is
/// the only place they can be — CI stays hermetic and downloads nothing.
///
/// Both were built from the same tree:
///
/// ```text
/// wrapper/Fixture.sfz
/// wrapper/README
/// wrapper/Samples/a.wav
/// wrapper/Samples/b.wav
/// ```
///
/// The tar has the `wrapper/` prefix (so `stripComponents: 1` is exercised);
/// the zip was made from inside it (so `stripComponents: 0` is).
enum ArchiveFixtures {
    /// 384 bytes; SHA-256 8181ba6587c217c7c20f86b1c8ff586c93492ddf38c2ac56455664824c498aaa
    static let tarXZBase64 = """
        /Td6WFoAAATm1rRGBMC/AoAwIQEcAAAAAAAAAMpaxnbgF/8BN10AO5yIRsez1cTTqNxnVE03GKha
        +6s0pdCMinlXAwEGHG3p40R9KJvOAlEGYJBHUtJ99QjO7L+IoRNbgokGImeHqVrR8g1rwF+pH5ml
        sO/fgveH5q03+ZizM1WhwzMEjn1JXj6UIzFFtGkUt0bMfD7wdsCyDBC0IiWfLPoBBGRIe8X/pR32
        kH1zZ3lBNngbLAEilZ2FSnkJjQxsUOgry9ibDE7BW4EwVVNNYxOeiUZw0IKSKLL88Xfr+sBVJxkp
        Mxq9kZrlnpAnNRbVJjqxTQ9XyPgAF+U312ZhVCC5ilaa4HAnFMC0bb+w5ZBkvX+p2W3kMAufRiJ5
        E6l8/xRgmAYFAOOzwoiiYJZ7mA6YL0Ej6jQ0BR58BPYiZJFkh+Zodj4tuov9lXKbf8NDeSd4t64a
        PqtBAyIZFgAAAKWqi2SEOMKiAAHbAoAwAAD6OF4IscRn+wIAAAAABFla
        """

    /// 899 bytes; SHA-256 5de105488e46aebd0ad286af9bb3d3da41718060660fc2214ab1a2c38f6170e6
    static let zipBase64 = """
        UEsDBBQAAAAIAFJYHF3Lix5pNAAAADUAAAALABwARml4dHVyZS5zZnpVVAkAAyy/kWotv5FqdXgL
        AAEE9QEAAAQAAAAAs0nOzyspys+x40pJTUsszSmJL0gsybANTswtyEktjuGyKUpNz8zPsysGC9gm
        6pUnlnEBAFBLAwQKAAAAAABSWBxd0qzv3wkAAAAJAAAABgAcAFJFQURNRVVUCQADLL+Rai2/kWp1
        eAsAAQT1AQAABAAAAABhIHJlYWRtZQpQSwMECgAAAAAAUlgcXQAAAAAAAAAAAAAAAAgAHABTYW1w
        bGVzL1VUCQADLL+Rai2/kWp1eAsAAQT1AQAABAAAAABQSwMECgAAAAAAUlgcXVZE0tAgAAAAIAAA
        AA0AHABTYW1wbGVzL2Eud2F2VVQJAAMsv5FqLb+RanV4CwABBPUBAAAEAAAAAFJJRkYtLS0tV0FW
        RWZtdCAwMTIzNDU2Nzg5YWJjZGVmUEsDBAoAAAAAAFJYHF3DgM7JKgAAACoAAAANABwAU2FtcGxl
        cy9iLndhdlVUCQADLL+Rai2/kWp1eAsAAQT1AQAABAAAAABzZWNvbmQgc2FtcGxlIHBheWxvYWQg
        Zm9yIHRoZSBhcmNoaXZlIHRlc3RQSwECHgMUAAAACABSWBxdy4seaTQAAAA1AAAACwAYAAAAAAAB
        AAAApIEAAAAARml4dHVyZS5zZnpVVAUAAyy/kWp1eAsAAQT1AQAABAAAAABQSwECHgMKAAAAAABS
        WBxd0qzv3wkAAAAJAAAABgAYAAAAAAABAAAApIF5AAAAUkVBRE1FVVQFAAMsv5FqdXgLAAEE9QEA
        AAQAAAAAUEsBAh4DCgAAAAAAUlgcXQAAAAAAAAAAAAAAAAgAGAAAAAAAAAAQAO1BwgAAAFNhbXBs
        ZXMvVVQFAAMsv5FqdXgLAAEE9QEAAAQAAAAAUEsBAh4DCgAAAAAAUlgcXVZE0tAgAAAAIAAAAA0A
        GAAAAAAAAQAAAKSBBAEAAFNhbXBsZXMvYS53YXZVVAUAAyy/kWp1eAsAAQT1AQAABAAAAABQSwEC
        HgMKAAAAAABSWBxdw4DOySoAAAAqAAAADQAYAAAAAAABAAAApIFrAQAAU2FtcGxlcy9iLndhdlVU
        BQADLL+RanV4CwABBPUBAAAEAAAAAFBLBQYAAAAABQAFAJEBAADcAQAAAAA=
        """

    static var tarXZ: Data { Data(base64Encoded: tarXZBase64, options: .ignoreUnknownCharacters)! }
    static var zip: Data { Data(base64Encoded: zipBase64, options: .ignoreUnknownCharacters)! }

    /// What both archives expand to, after their wrapper is stripped.
    static let expectedContents: [String: String] = [
        "Fixture.sfz": "<control>\ndefault_path=Samples\\\n<region>sample=a.wav\n",
        "README": "a readme\n",
        "Samples/a.wav": "RIFF----WAVEfmt 0123456789abcdef",
        "Samples/b.wav": "second sample payload for the archive test"
    ]
}
