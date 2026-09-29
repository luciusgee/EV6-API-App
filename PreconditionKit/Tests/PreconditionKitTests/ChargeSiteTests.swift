import XCTest
@testable import PreconditionKit

final class ChargeSiteTests: XCTestCase {
    func testPolylineMatchesGooglesExample() {
        let points = [LatLon(lat: 38.5, lon: -120.2), LatLon(lat: 40.7, lon: -120.95), LatLon(lat: 43.252, lon: -126.453)]
        XCTAssertEqual(Polyline.encode(points), "_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        let many = (0..<1000).map { LatLon(lat: Double($0), lon: 0) }
        let simple = Polyline.simplify(many, maxPoints: 150)
        XCTAssertEqual(simple.count, 150)
        XCTAssertEqual(simple.first, many.first)
        XCTAssertEqual(simple.last, many.last)
    }

    static let ocm = #"""
    [{"ID":123456,"UsageCost":"£0.74/kWh","NumberOfPoints":6,
      "AddressInfo":{"Title":"Ionity Leeds Skelton Lake","AddressLine1":"Skelton Lake Services","Town":"Leeds","Postcode":"LS15 0AW","Latitude":53.77,"Longitude":-1.47},
      "OperatorInfo":{"Title":"IONITY"},"UsageType":{"Title":"Public - Pay At Location"},
      "StatusType":{"IsOperational":true,"Title":"Operational"},"DateLastStatusUpdate":"2026-08-01T10:00:00Z","DateLastVerified":"2026-07-01T10:00:00Z",
      "Connections":[
        {"ConnectionTypeID":33,"ConnectionType":{"Title":"CCS (Type 2)"},"StatusType":{"IsOperational":true},"LevelID":3,"PowerKW":350,"CurrentTypeID":30,"Quantity":6},
        {"ConnectionTypeID":25,"ConnectionType":{"Title":"Type 2 (Socket Only)"},"LevelID":2,"PowerKW":22,"CurrentTypeID":20,"Quantity":2}],
      "UserComments":[
        {"Comment":"All 6 working, 230 kW on my EV6","Rating":5,"UserName":"ev6driver","DateCreated":"2026-09-20T12:00:00Z","CheckinStatusType":{"Title":"Charged Successfully","IsPositive":true}},
        {"Comment":"One unit down","Rating":3,"UserName":"someone","DateCreated":"2026-08-02T09:00:00Z","CheckinStatusType":{"Title":"Charged Successfully","IsPositive":true}}]},
     {"ID":2,"AddressInfo":{"Title":"No position"}}]
    """#

    func testParsesAnOpenChargeMapSite() async throws {
        let server = ScriptedTransport()
        server.setDefault("/v3/poi", jsonResponse(Self.ocm))
        let client = OpenChargeMapClient(transport: server, key: "k")
        let sites = try await client.along([LatLon(lat: 53.8, lon: -1.5), LatLon(lat: 52.0, lon: -1.2)])
        XCTAssertEqual(sites.count, 1, "the one without a position is dropped")
        let s = sites[0]
        XCTAssertEqual(s.id, "ocm-123456")
        XCTAssertEqual(s.operatorName, "IONITY")
        XCTAssertEqual(s.address, "Skelton Lake Services, Leeds, LS15 0AW")
        XCTAssertEqual(s.maxKW, 350)
        XCTAssertEqual(s.rapidCount, 6)
        XCTAssertEqual(s.cost, "£0.74/kWh")
        XCTAssertEqual(s.operational, true)
        XCTAssertEqual(s.comments.first?.text, "All 6 working, 230 kW on my EV6")
        XCTAssertEqual(s.rating, 4)
        let q = try XCTUnwrap(server.last("/v3/poi")?.url.query)
        XCTAssertTrue(q.contains("key=k"))
        XCTAssertTrue(q.contains("polyline="))
        XCTAssertTrue(q.contains("minpowerkw=40"))
        XCTAssertTrue(q.contains("includecomments=true"))

        server.setDefault("/v3/poi", HTTPResponse(status: 403, text: "You must specify an API key"))
        do {
            _ = try await client.near(LatLon(lat: 53.8, lon: -1.5))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? OpenChargeMapClient.Failure, .badKey)
        }
    }

    func testParsesGoogleLiveAvailabilityAndReviews() async throws {
        let server = ScriptedTransport()
        server.setDefault("places:searchNearby", jsonResponse(#"""
        {"places":[
          {"displayName":{"text":"Far away"},"location":{"latitude":53.9,"longitude":-1.47}},
          {"displayName":{"text":"IONITY Skelton Lake"},"location":{"latitude":53.7701,"longitude":-1.4701},"rating":4.3,"userRatingCount":87,
           "googleMapsUri":"https://maps.google.com/?cid=1",
           "evChargeOptions":{"connectorCount":6,"connectorAggregation":[{"type":"EV_CONNECTOR_TYPE_CCS_COMBO_2","maxChargeRateKw":350,"count":6,"availableCount":4,"outOfServiceCount":1,"availabilityLastUpdateTime":"2026-09-29T14:55:00Z"}]},
           "reviews":[{"rating":5,"text":{"text":"Quick and clean"},"authorAttribution":{"displayName":"Sam"},"relativePublishTimeDescription":"a week ago"}]}]}
        """#))
        let google = GooglePlacesClient(transport: server, key: "g")
        let info = try await google.insight(near: LatLon(lat: 53.77, lon: -1.47))
        XCTAssertEqual(info.name, "IONITY Skelton Lake")
        XCTAssertEqual(info.availability.first?.type, "CCS")
        XCTAssertEqual(info.availability.first?.available, 4)
        XCTAssertEqual(info.availability.first?.outOfService, 1)
        XCTAssertEqual(info.ratingCount, 87)
        XCTAssertEqual(info.reviews.first?.text, "Quick and clean")
        let request = try XCTUnwrap(server.last("places:searchNearby"))
        XCTAssertEqual(request.header("X-Goog-Api-Key"), "g")
        XCTAssertTrue(request.header("X-Goog-FieldMask")?.contains("places.evChargeOptions") == true)
    }
}
