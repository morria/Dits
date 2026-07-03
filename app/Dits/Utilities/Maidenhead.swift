// Maidenhead grid-locator helpers: derive a grid from coordinates (for
// the "use my location" button) and compute great-circle distance
// between two grids (for the conversation header).

import Foundation
import CoreLocation

enum Maidenhead {

    /// 6-character grid (e.g. "FN31pr") for a coordinate.
    static func grid(latitude: Double, longitude: Double) -> String {
        // Clamp: exactly lon 180 / lat 90 would index one field past "R".
        var lon = min(max(longitude, -180), 179.9999) + 180
        var lat = min(max(latitude, -90), 89.9999) + 90

        let A = UnicodeScalar("A").value
        let a = UnicodeScalar("a").value
        let zero = UnicodeScalar("0").value

        func ch(_ v: UInt32) -> Character { Character(UnicodeScalar(v)!) }

        var grid = ""
        // Field (20° lon, 10° lat)
        grid.append(ch(A + UInt32(lon / 20)))
        grid.append(ch(A + UInt32(lat / 10)))
        lon = lon.truncatingRemainder(dividingBy: 20)
        lat = lat.truncatingRemainder(dividingBy: 10)
        // Square (2° lon, 1° lat)
        grid.append(ch(zero + UInt32(lon / 2)))
        grid.append(ch(zero + UInt32(lat / 1)))
        lon = lon.truncatingRemainder(dividingBy: 2)
        lat = lat.truncatingRemainder(dividingBy: 1)
        // Subsquare (5' lon, 2.5' lat)
        grid.append(ch(a + UInt32(lon * 12)))
        grid.append(ch(a + UInt32(lat * 24)))
        return grid
    }

    /// Center coordinate of a 4- or 6-character grid, or nil if malformed.
    static func coordinate(of grid: String) -> CLLocationCoordinate2D? {
        let g = Array(grid.uppercased())
        guard g.count >= 4 else { return nil }
        let A = Character("A").asciiValue!
        let zero = Character("0").asciiValue!

        guard let f0 = g[0].asciiValue, let f1 = g[1].asciiValue,
              let s0 = g[2].asciiValue, let s1 = g[3].asciiValue else { return nil }

        var lon = Double(Int(f0) - Int(A)) * 20 - 180
        var lat = Double(Int(f1) - Int(A)) * 10 - 90
        lon += Double(Int(s0) - Int(zero)) * 2
        lat += Double(Int(s1) - Int(zero)) * 1

        if g.count >= 6, let ss0 = g[4].asciiValue, let ss1 = g[5].asciiValue {
            lon += (Double(Int(ss0) - Int(A)) + 0.5) * (2.0 / 24.0)
            lat += (Double(Int(ss1) - Int(A)) + 0.5) * (1.0 / 24.0)
        } else {
            lon += 1.0       // center of square
            lat += 0.5
        }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Great-circle distance in kilometers between two grids.
    static func distanceKm(from: String, to: String) -> Double? {
        guard let a = coordinate(of: from), let b = coordinate(of: to) else { return nil }
        let la = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let lb = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return la.distance(from: lb) / 1000.0
    }

    /// Loose validity check for user-entered grids.
    static func isValid(_ grid: String) -> Bool {
        let g = grid.uppercased()
        guard g.count == 4 || g.count == 6 else { return false }
        let chars = Array(g)
        func isAlpha(_ c: Character) -> Bool { c.isLetter }
        func isDigit(_ c: Character) -> Bool { c.isNumber }
        guard isAlpha(chars[0]), isAlpha(chars[1]), isDigit(chars[2]), isDigit(chars[3]) else { return false }
        if g.count == 6 { return isAlpha(chars[4]) && isAlpha(chars[5]) }
        return true
    }
}
