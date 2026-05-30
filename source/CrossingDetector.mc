import Toybox.Lang;
import Toybox.Math;

// Detects when the user crosses an Ortsschild (town entry sign).
//
// GPS updates every ~1 second, so we track the distance to a sign across ticks.
// When the distance was decreasing (approaching) and then increases again, the
// minimum point was the crossing. We interpolate the exact crossing time from
// the two surrounding GPS ticks.
class CrossingDetector {
    // Must come within CROSSING_M meters to count as a crossing
    private const CROSSING_M  = 80.0f;

    private var _prevDist    as Float?;
    private var _prevTimeSec as Numeric?;
    private var _approaching as Boolean = false;

    public function initialize() {
        reset();
    }

    public function reset() as Void {
        _prevDist    = null;
        _prevTimeSec = null;
        _approaching = false;
    }

    // Feed the current distance to the target sign and current wall-clock time
    // (seconds since epoch, from Time.now().value()).
    // Returns the interpolated crossing time in the same epoch, or null.
    public function update(distMeters as Float, nowSec as Numeric) as Numeric? {
        if (_prevDist == null) {
            _prevDist    = distMeters;
            _prevTimeSec = nowSec;
            return null;
        }

        var prev     = _prevDist as Float;
        var prevTime = _prevTimeSec as Numeric;
        var crossed  = null as Numeric?;

        if (distMeters < prev) {
            // Still approaching
            _approaching = true;
        } else if (_approaching && distMeters > prev && prev < CROSSING_M) {
            // Was approaching, now moving away, and we passed within CROSSING_M → crossed!
            // Interpolate: fraction of the [prev→curr] interval where distance = 0
            var dt       = nowSec - prevTime;
            var fraction = prev / (prev + distMeters);
            crossed      = prevTime + fraction * dt;
            _approaching = false;
        }

        _prevDist    = distMeters;
        _prevTimeSec = nowSec;
        return crossed;
    }

    // Great-circle distance in metres via Haversine formula.
    // Inputs are decimal degrees (the format returned by Position.Location.toDegrees()).
    public static function haversine(
        lat1 as Float, lon1 as Float,
        lat2 as Float, lon2 as Float
    ) as Float {
        var R    = 6371000.0;
        var dLat = (lat2 - lat1) * Math.PI / 180.0;
        var dLon = (lon2 - lon1) * Math.PI / 180.0;
        var rlat1 = lat1 * Math.PI / 180.0;
        var rlat2 = lat2 * Math.PI / 180.0;
        var a = Math.sin(dLat / 2.0) * Math.sin(dLat / 2.0)
              + Math.cos(rlat1) * Math.cos(rlat2)
              * Math.sin(dLon / 2.0) * Math.sin(dLon / 2.0);
        return (R * 2.0 * Math.asin(Math.sqrt(a))).toFloat();
    }
}
