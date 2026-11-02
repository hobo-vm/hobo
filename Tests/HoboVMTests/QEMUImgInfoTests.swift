import Foundation
import Testing
@testable import HoboVM

/// A recipe's cloud image is someone else's file: only a self-contained qcow2 or raw image is
/// converted, never one that would pull host files into the disk. Needs no VM.
@Suite struct QEMUImgInfoTests {
    func parse(_ json: String) throws -> QEMUImg.Info {
        try QEMUImg.parseInfo(Data(json.utf8), image: "disk1.img")
    }

    @Test func acceptsASelfContainedQCOW2() throws {
        let info = try parse("""
            {"format": "qcow2", "virtual-size": 3758096384, "format-specific": {"type": "qcow2", "data": {"compat": "1.1"}}}
            """)
        #expect(info.format == "qcow2")
        #expect(info.virtualSize == 3_758_096_384)
    }

    @Test func acceptsRaw() throws {
        #expect(try parse(#"{"format": "raw", "virtual-size": 512}"#).virtualSize == 512)
    }

    @Test func rejectsABackingFile() {
        #expect(throws: VMError.self) {
            try parse(#"{"format": "qcow2", "virtual-size": 1048576, "backing-filename": "/etc/hosts"}"#)
        }
    }

    @Test func rejectsAnExternalDataFile() {
        #expect(throws: VMError.self) {
            try parse(#"{"format": "qcow2", "virtual-size": 1048576, "format-specific": {"type": "qcow2", "data": {"data-file": "/etc/hosts"}}}"#)
        }
    }

    @Test func rejectsOtherFormats() {
        #expect(throws: VMError.self) { try parse(#"{"format": "vmdk", "virtual-size": 1048576}"#) }
    }
}
