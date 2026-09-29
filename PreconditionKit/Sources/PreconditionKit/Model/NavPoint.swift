import Foundation

/// A place to send to the car's nav (Kia's "send to car").
public struct NavPoint: Codable, Equatable, Sendable {
    public var name: String
    public var position: LatLon
    public var address: String

    public init(name: String, position: LatLon, address: String = "") {
        self.name = name
        self.position = position
        self.address = address
    }

    /// Kia's `location/routes` body: the stops in driving order, the destination last.
    static func requestBody(_ points: [NavPoint], deviceId: String) -> JSONValue {
        let list: [JSONValue] = points.enumerated().map { i, p in
            [
                "phone": "",
                "waypointID": .number(Double(i)),
                "lang": 1,
                "src": "HERE",
                "coord": ["lat": .number(p.position.lat), "alt": 0, "lon": .number(p.position.lon), "type": 0],
                "addr": .string(p.address),
                "zip": "",
                "placeid": .string(p.name),
                "name": .string(p.name),
            ]
        }
        return ["deviceID": .string(deviceId), "poiInfoList": .array(list)]
    }
}
