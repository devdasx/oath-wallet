import Darwin
import Foundation
import OathArtworkSource
import XCTest
@testable import OathTokenImages

private actor HostProbeTransport: ArtworkTransport {
    private(set) var count = 0
    func data(from url: URL) async throws -> Data {
        count += 1
        return Data("<svg xmlns='http://www.w3.org/2000/svg' width='2' height='2'><rect width='2' height='2'/></svg>".utf8)
    }
}

final class ArtworkHostPolicyTests: XCTestCase, @unchecked Sendable {
    func testResolverRecognizedIPv4SpellingsAreRejected() throws {
        for (input, canonical) in [
            ("0x7f.0.0.1", "127.0.0.1"), ("127.0x0.1", "127.0.0.1"),
            ("0x7f.1","127.0.0.1"), ("0x7f.0x1","127.0.0.1"), ("0xA9.0xfe.0.1","169.254.0.1"),
            ("%30%78%37%66.1","127.0.0.1"), ("0xc0.0250.1.1","192.168.1.1")
        ] {
            let url = try XCTUnwrap(URL(string: "https://"+input+"/icon"))
            let host = try XCTUnwrap(url.host)
            var actual = in_addr(), expected = in_addr()
            XCTAssertEqual(inet_aton(host, &actual), 1)
            XCTAssertEqual(inet_pton(AF_INET, canonical, &expected), 1)
            XCTAssertEqual(actual.s_addr, expected.s_addr)
            XCTAssertFalse(ArtworkSource.permits(url),input)
        }
    }

    func testEscapedDelimitersAndMalformedLabelsAreRejected() {
        for host in ["127.1%00.example","cdn.example%2f..%2flocalhost","host%09name.example","cdn..example","-cdn.example","cdn-.example"] {
            XCTAssertNil(ArtworkSource.normalized("https://"+host+"/a"),host)
        }
    }

    func testHomeZoneIsRejected() {
        for host in ["home.arpa","pRiNtEr.HOME.arpa"] {
            XCTAssertNil(ArtworkSource.normalized("https://"+host+"/a"),host)
        }
    }

    func testSignedThumbnailCannotIntroduceNumericOriginal() {
        let original = "https://0x7f.1/asset"
        let encoded = Data(original.utf8).base64EncodedString().replacingOccurrences(of:"=",with:"")
        let proxy = "https://cache.tonapi.io/imgproxy/signature/"+encoded+".webp"
        XCTAssertEqual(ArtworkSource.candidates([proxy]),[proxy])
    }

    func testUntrustedLogoNeverReachesLoaderTransport() async {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let transport=HostProbeTransport()
        let loader=ArtworkLoader(directory:folder,transport:transport)
        let image=await loader.image(for:["https://0x7f.1/asset"])
        let count=await transport.count
        XCTAssertNil(image)
        XCTAssertEqual(count,0)
    }

    private func redirect(to url: URL) async -> URL? {
        let start=URL(string:"https://cdn.example.org/old")!
        let session=URLSession(configuration:.ephemeral)
        defer { session.invalidateAndCancel() }
        let task=session.dataTask(with:start) // Invoke the delegate directly. Never resume a socket task.
        let response=HTTPURLResponse(url:start,statusCode:302,httpVersion:nil,headerFields:nil)!
        return await withCheckedContinuation { done in
            ArtworkURLTransport().urlSession(session, task:task, willPerformHTTPRedirection:response,
                newRequest:URLRequest(url:url)) { done.resume(returning:$0?.url) }
        }
    }

    func testRedirectRejectsNumericHost() async {
        let target=URL(string:"https://0x7f.0.0.1/asset")!
        let result=await redirect(to:target)
        XCTAssertNil(result)
    }

    func testPublicDNSAndGatewayCompatibility() throws {
        for value in ["https://cdn.example.org/a?q=1","https://0x7f.assets.example.org/logo","https://xn--bcher-kva.example/a","https://not-home.arpa.example/icon"] {
            XCTAssertEqual(ArtworkSource.normalized(value),value)
        }
        XCTAssertNotNil(ArtworkSource.normalized("https://bücher.example/img"))
        XCTAssertNotNil(ArtworkSource.normalized("https://%62%C3%BCcher.example/img"))
        XCTAssertEqual(ArtworkSource.normalized("http://cdn.example.org/a"),"https://cdn.example.org/a")
        XCTAssertEqual(ArtworkSource.normalized("ipfs://bafyexample/image"),"https://ipfs.io/ipfs/bafyexample/image")
        XCTAssertEqual(ArtworkSource.normalized("ar://abc/icon"),"https://arweave.net/abc/icon")
    }

    func testRedirectPreservesPublicDestination() async {
        let target=URL(string:"https://cdn.example.org:443/new?q=1")!
        let result=await redirect(to:target)
        XCTAssertEqual(result,target)
    }
}
