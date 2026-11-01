import Foundation

/// Solar elevation (degrees above the horizon, no refraction) after the common NOAA approximation (accurate to a fraction
/// of a degree). Used only to tell a legitimately dark night image from a broken one.
public enum SunElevation {
    public static func degrees(lat: Double, lon: Double, at date: Date) -> Double {
        let jd = date.timeIntervalSince1970 / 86400 + 2440587.5
        let t = (jd - 2451545.0) / 36525
        let l0 = (280.46646 + t * (36000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let m = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let mr = m * .pi / 180
        let c = sin(mr) * (1.914602 - t * (0.004817 + 0.000014 * t)) + sin(2 * mr) * (0.019993 - 0.000101 * t) + sin(3 * mr) * 0.000289
        let trueLong = l0 + c
        let omega = 125.04 - 1934.136 * t
        let lambda = (trueLong - 0.00569 - 0.00478 * sin(omega * .pi / 180)) * .pi / 180
        let eps0 = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let eps = (eps0 + 0.00256 * cos(omega * .pi / 180)) * .pi / 180
        let decl = asin(sin(eps) * sin(lambda))
        let y = pow(tan(eps / 2), 2)
        let l0r = l0 * .pi / 180, e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let eqTime = 4 * (y * sin(2 * l0r) - 2 * e * sin(mr) + 4 * e * y * sin(mr) * cos(2 * l0r)
                          - 0.5 * y * y * sin(4 * l0r) - 1.25 * e * e * sin(2 * mr)) * 180 / .pi  // minutes
        let minutesUTC = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400) / 60
        let trueSolarTime = (minutesUTC + eqTime + 4 * lon).truncatingRemainder(dividingBy: 1440)
        let hourAngle = (trueSolarTime / 4 - 180) * .pi / 180
        let latR = lat * .pi / 180
        let sinElev = sin(latR) * sin(decl) + cos(latR) * cos(decl) * cos(hourAngle)
        return asin(max(-1, min(1, sinElev))) * 180 / .pi
    }
}
