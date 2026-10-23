import Foundation
import XCTest
@testable import PreconditionKit

final class JSONValueTests: XCTestCase {
    func testParsesAndReadsLeniently() throws {
        let v = try XCTUnwrap(JSONValue.parse(#"{"a":{"b":[{"c":"12.5"}]},"t":true,"one":1,"zero":"0","s":"x","n":null}"#))
        XCTAssertEqual(v.path("a.b.0.c")?.num, 12.5)
        XCTAssertNil(v.path("a.b.1.c"))
        XCTAssertNil(v.path("a.x.y"))
        XCTAssertEqual(v["t"]?.bool, true)
        XCTAssertEqual(v["one"]?.bool, true)
        XCTAssertEqual(v["zero"]?.bool, false)
        XCTAssertNil(v["s"]?.bool)
        XCTAssertEqual(v["one"]?.str, "1")
        XCTAssertEqual(v["t"]?.str, "true")
        XCTAssertEqual(v["n"], .null)
        XCTAssertNil(v["n"]?.str)
        XCTAssertNil(JSONValue.parse("not json"))
    }

    func testPrintsStableCompactJSON() {
        let v: JSONValue = ["b": 1, "a": [true, nil, 10.9, "x/y"]]
        XCTAssertEqual(v.text, #"{"a":[true,null,10.9,"x/y"],"b":1}"#)
        XCTAssertEqual(JSONValue.parse(v.text), v)
    }
}

final class DigestTests: XCTestCase {
    func testPortableSHA256MatchesKnownVectors() {
        XCTAssertEqual(Digest.hex(PortableSHA256.hash([])), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Digest.hex(PortableSHA256.hash(Array("abc".utf8))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            Digest.hex(PortableSHA256.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
        // Longer than one block.
        let million = [UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000)
        XCTAssertEqual(Digest.hex(PortableSHA256.hash(million)), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testPlatformDigestAgreesWithThePortableOne() {
        let token = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ABCDEFGHIJKL"
        XCTAssertEqual(Digest.sha256Hex(token), Digest.hex(PortableSHA256.hash(Array(token.utf8))))
    }
}
