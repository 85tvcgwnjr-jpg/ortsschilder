import Toybox.Activity;
import Toybox.Application.Storage;
import Toybox.Background;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.WatchUi;

// Custom DataField — NO Communications allowed in DataField context on Edge devices.
// All HTTP is handled exclusively by OrtsschilderBackground.
//
// DataField responsibilities:
//   - Read GPS, detect sign crossings
//   - Queue crossings in Storage (Background uploads them)
//   - Trigger Background via temporal event when needed
//   - Read signs + rank results from Storage
//   - ANT+ peer-to-peer live ranking
//
// Display states:
//   noGps       - waiting for GPS fix
//   idle        - no sign within 20 km, or signs still loading
//   approaching - 100–500 m to next sign
//   sprint      - under 100 m
//   result      - just crossed a sign (30 s)
class OrtsschilderField extends WatchUi.DataField {

    private const SK_SIGNS     = "signs";
    private const SK_CROSSINGS = "crossings";

    private const ST_NO_GPS   = 0;
    private const ST_IDLE     = 1;
    private const ST_APPROACH = 2;
    private const ST_SPRINT   = 3;
    private const ST_RESULT   = 4;

    // Server rank status (populated from Storage after Background fetches it)
    private const RS_IDLE    = 0;
    private const RS_LOADING = 1;
    private const RS_DONE    = 2;
    private const RS_OFFLINE = 3;

    // Display-distance thresholds (metres). Crossing threshold itself lives in
    // CrossingDetector; these only drive the sprint/approach display states.
    private const SPRINT_M   = 100.0;
    private const APPROACH_M = 500.0;
    // Beyond this distance the nearest sign is ignored entirely.
    private const MAX_SIGN_M = 20000.0;

    private var _state        as Number      = ST_NO_GPS;
    private var _signs        as Array       = [] as Array;
    private var _nearest      as Dictionary? = null;
    private var _nearestDist  as Float?      = null;
    private var _detector     as CrossingDetector?;
    private var _resultTicks  as Number      = 0;

    // ANT+ peer-to-peer
    private var _ant         as OrtsschilderAnt?;
    private var _myDevHash   as Number  = 0;
    private var _myDevId     as String  = "dev0";
    private var _myTs        as Number? = null;
    private var _mySignHash  as Number  = 0;
    private var _leaderTs    as Number? = null;

    // Crossing state
    private var _lastCrossedName as String = "";

    // GPS track recording
    private var _trackPoints   as Array  = [] as Array;
    private var _lastSampleSec as Number = 0;
    private var _activityStart as Number = 0;

    // Background coordination
    private var _gpsTriggered    as Boolean = false;
    private var _lastSignReload  as Number  = 0;
    private var _lastBgTrigger   as Number  = 0;  // when we last triggered Background
    private var _lastPosUpdate   as Number  = 0;  // when we last wrote current_pos

    // Server ranking (read from Storage, written by Background)
    private var _rankStatus  as Number = RS_IDLE;
    private var _rankPos     as Number = 0;
    private var _rankTotal   as Number = 0;
    private var _rankDelta   as Float  = 0.0f;
    private var _lastRankCheck as Number = 0;

    // Debug
    private var _debugLine as String = "";

    public function initialize() {
        DataField.initialize();
        _debugLine = "init";
        try {
            _detector = new CrossingDetector();
        } catch (e instanceof Lang.Exception) { _debugLine = "det fail"; return; }
        try {
            _signs = _loadSigns();
        } catch (e instanceof Lang.Exception) { _signs = [] as Array; }
        try {
            _ant = new OrtsschilderAnt(method(:onAntRx));
        } catch (e instanceof Lang.Exception) { _debugLine = "ant fail"; }
        try {
            var settings = System.getDeviceSettings();
            _myDevId = (settings has :uniqueIdentifier && settings.uniqueIdentifier != null)
                       ? settings.uniqueIdentifier.toString()
                       : "dev0";
            _myDevHash = hashStr(_myDevId);
        } catch (e instanceof Lang.Exception) {}
        _debugLine = "";
    }

    // ─── compute() — called every second ─────────────────────────────────────

    public function compute(info as Activity.Info) as Void {
        try {
            _computeInner(info);
        } catch (e instanceof Lang.Exception) {
            try {
                var msg = (e as Lang.Exception).getErrorMessage();
                _debugLine = (msg != null) ? msg.toString() : "ERR";
            } catch (e2 instanceof Lang.Exception) {
                _debugLine = "ERR";
            }
        }
    }

    private function _computeInner(info as Activity.Info) as Void {
        var nowSec = Time.now().value();

        var ant = _ant;
        if (ant != null) { (ant as OrtsschilderAnt).tick(nowSec); }

        // Result countdown
        if (_state == ST_RESULT) {
            _resultTicks--;

            // Poll Storage for rank result written by Background
            if (_rankStatus == RS_LOADING && nowSec - _lastRankCheck >= 3) {
                _lastRankCheck = nowSec;
                var rr = Storage.getValue("rank_result");
                if (rr instanceof Dictionary) {
                    var rd    = rr as Dictionary;
                    var pos   = rd.get("pos");
                    var total = rd.get("total");
                    var delta = rd.get("delta");
                    if (pos instanceof Number && total instanceof Number) {
                        _rankPos    = pos   as Number;
                        _rankTotal  = total as Number;
                        _rankDelta  = (delta instanceof Float) ? (delta as Float) : 0.0f;
                        _rankStatus = RS_DONE;
                    }
                }
            }

            if (_resultTicks <= 0) {
                _state      = ST_IDLE;
                _myTs       = null;
                _leaderTs   = null;
                _nearest    = null;
                _rankStatus = RS_IDLE;
                var detR = _detector;
                if (detR != null) { (detR as CrossingDetector).reset(); }
            }
            return;
        }

        var loc = info.currentLocation;
        if (loc == null) {
            _state = ST_NO_GPS;
            return;
        }

        var coords = loc.toDegrees();
        var lat    = (coords[0] as Numeric).toFloat();
        var lon    = (coords[1] as Numeric).toFloat();

        // First GPS fix → store position + trigger Background in 5 s
        if (!_gpsTriggered) {
            _gpsTriggered  = true;
            _lastBgTrigger = nowSec;
            _lastPosUpdate = nowSec;
            Storage.setValue("current_pos", [lat, lon] as Array);
            _triggerBackground(5);
        }

        // Update stored position every 60 s so Background always has a fresh location
        if (nowSec - _lastPosUpdate >= 60) {
            _lastPosUpdate = nowSec;
            Storage.setValue("current_pos", [lat, lon] as Array);
        }

        // GPS track sample every 30 s — cap at 120 points (~1h) to protect RAM
        if (nowSec - _lastSampleSec >= 30) {
            _lastSampleSec = nowSec;
            if (_trackPoints.size() < 120) {
                _trackPoints.add([lat, lon, nowSec] as Array);
            }
        }

        // Reload signs from Storage every 30 s (picks up Background OSM updates)
        if (nowSec - _lastSignReload >= 30) {
            _lastSignReload = nowSec;
            var fresh = Storage.getValue(SK_SIGNS);
            if (fresh instanceof Array && (fresh as Array).size() > 0) {
                _signs = fresh as Array;
            }
        }

        _findNearest(lat, lon);

        var nearest = _nearest;
        if (nearest == null) {
            _state = ST_IDLE;
            return;
        }

        var dist = _nearestDist as Float;
        var det  = _detector;
        if (det == null) { _state = ST_IDLE; return; }
        var crossTime = (det as CrossingDetector).update(dist, nowSec);

        if (crossTime != null) {
            _recordCrossing(nearest, crossTime, nowSec);
            return;
        }

        if (dist < SPRINT_M) {
            _state = ST_SPRINT;
        } else if (dist < APPROACH_M) {
            _state = ST_APPROACH;
        } else {
            _state = ST_IDLE;
        }
    }

    // ─── onUpdate() — rendering ───────────────────────────────────────────────

    public function onUpdate(dc as Graphics.Dc) as Void {
        var w  = dc.getWidth();
        var h  = dc.getHeight();
        var cx = w / 2;

        // Heartbeat: drawn first with hardcoded colors before anything can crash.
        // Visible → onUpdate() is alive. Green icon instead → initialize() crashed.
        dc.setColor(0xFFFFFF, 0x000000);
        dc.clear();
        dc.drawText(cx, h / 2, Graphics.FONT_SMALL,
                    _debugLine.equals("") ? _stateLabel() : _debugLine,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Full rendering pass (overwrites heartbeat on success)
        try {
            var bgColor = Graphics.COLOR_BLACK;
            var fgColor = Graphics.COLOR_WHITE;
            try {
                bgColor = getBackgroundColor();
                fgColor = (bgColor == Graphics.COLOR_BLACK)
                          ? Graphics.COLOR_WHITE
                          : Graphics.COLOR_BLACK;
            } catch (e instanceof Lang.Exception) {}

            dc.setColor(fgColor, bgColor);
            dc.clear();

            switch (_state) {
                case ST_NO_GPS:
                    _text(dc, cx, h / 2, Graphics.FONT_SMALL, "GPS...", fgColor, bgColor);
                    break;
                case ST_IDLE:
                    _drawIdle(dc, w, h, cx, fgColor, bgColor);
                    break;
                case ST_APPROACH:
                    _drawDistance(dc, w, h, cx, fgColor, bgColor, Graphics.COLOR_YELLOW);
                    break;
                case ST_SPRINT:
                    _drawDistance(dc, w, h, cx, fgColor, bgColor, Graphics.COLOR_RED);
                    break;
                case ST_RESULT:
                    _drawResult(dc, w, h, cx, fgColor, bgColor);
                    break;
                default:
                    _text(dc, cx, h / 2, Graphics.FONT_SMALL, "GPS...", fgColor, bgColor);
                    break;
            }

            if (!_debugLine.equals("")) {
                dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_BLACK);
                dc.drawText(cx, h - 12, Graphics.FONT_TINY, _debugLine,
                            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            }
        } catch (e instanceof Lang.Exception) {
            try {
                dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_BLACK);
                dc.drawText(cx, h - 12, Graphics.FONT_TINY, "ERR draw",
                            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            } catch (e2 instanceof Lang.Exception) {}
        }
    }

    // ─── ANT+ ─────────────────────────────────────────────────────────────────

    public function onAntRelease() as Void {
        var a = _ant;
        if (a != null) { (a as OrtsschilderAnt).release(); }
    }

    public function onAntRx(signHash as Number, devHash as Number, tsSec as Number) as Void {
        if (devHash == _myDevHash) { return; }
        if (_mySignHash != 0 && signHash != _mySignHash) { return; }
        var lt = _leaderTs;
        if (lt == null || tsSec < (lt as Number)) { _leaderTs = tsSec; }
        if (_state == ST_APPROACH || _state == ST_SPRINT) {
            _state       = ST_RESULT;
            _resultTicks = 30;
        }
    }

    // ─── Activity lifecycle ───────────────────────────────────────────────────

    public function onTimerStart() as Void {
        if (_activityStart == 0) { _activityStart = Time.now().value(); }
        Storage.setValue("activity_active", true);
        Storage.setValue("pending_ride", null);
    }

    public function onTimerStop() as Void {
        Storage.setValue("activity_active", false);
        if (_activityStart == 0 || _trackPoints.size() < 2) { return; }
        Storage.setValue("pending_ride", {
            "device_id"  => _myDevId,
            "started_at" => _activityStart,
            "ended_at"   => Time.now().value(),
            "gps_track"  => _trackPoints
        } as Dictionary);
    }

    public function onTimerReset() as Void {
        _trackPoints   = [] as Array;
        _activityStart = 0;
        _lastSampleSec = 0;
        Storage.setValue("activity_active", false);
        Storage.setValue("pending_ride", null);
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    private function _triggerBackground(delaySec as Number) as Void {
        try {
            Background.registerForTemporalEvent(
                Time.now().add(new Time.Duration(delaySec))
            );
        } catch (e instanceof Lang.Exception) {}
    }

    private function _findNearest(lat as Float, lon as Float) as Void {
        var bestDist    = 999999.0f;
        var bestSign    = null as Dictionary?;
        var bestDistAll = 999999.0f;
        var bestSignAll = null as Dictionary?;

        for (var i = 0; i < _signs.size(); i++) {
            var sign = _signs[i] as Dictionary;
            var latV = sign.get("lat");
            var lonV = sign.get("lon");
            if (latV == null || lonV == null) { continue; }
            var d = CrossingDetector.haversine(
                lat, lon,
                (latV instanceof Float) ? (latV as Float) : (latV as Number).toFloat(),
                (lonV instanceof Float) ? (lonV as Float) : (lonV as Number).toFloat()
            );
            if (d < bestDistAll) { bestDistAll = d; bestSignAll = sign; }
            var nameV = sign.get("name");
            if (nameV != null && nameV.toString().equals(_lastCrossedName)) { continue; }
            if (d < bestDist) { bestDist = d; bestSign = sign; }
        }

        if (bestSign == null) { bestSign = bestSignAll; bestDist = bestDistAll; }

        if (bestDist < MAX_SIGN_M) {
            _nearest     = bestSign;
            _nearestDist = bestDist;
        } else {
            _nearest     = null;
            _nearestDist = null;
        }
    }

    private function _recordCrossing(sign as Dictionary, crossTimeSec as Numeric,
                                      nowSec as Number) as Void {
        var signId   = sign.get("id").toString();
        var signName = sign.get("name").toString();
        _mySignHash      = hashStr(signId);
        _myTs            = crossTimeSec.toNumber();
        _leaderTs        = null;
        _lastCrossedName = signName;
        _rankStatus      = RS_LOADING;
        _rankPos         = 0;
        _rankTotal       = 0;
        _rankDelta       = 0.0f;
        _lastRankCheck   = nowSec;

        // ANT+ broadcast to nearby riders
        var antB = _ant;
        if (antB != null) {
            (antB as OrtsschilderAnt).broadcastCrossing(
                _mySignHash, _myDevHash, _myTs as Number, nowSec);
        }

        var event = {
            "sign_id"   => signId,
            "sign_name" => signName,
            "timestamp" => (_myTs as Number),
            "device_id" => _myDevId
        } as Dictionary;

        // Queue for Background upload
        var raw      = Storage.getValue(SK_CROSSINGS);
        var crossings = (raw instanceof Array) ? (raw as Array) : ([] as Array);
        crossings.add(event);
        Storage.setValue(SK_CROSSINGS, crossings);

        // Store crossing info so Background can fetch rankings after upload
        Storage.setValue("rank_result",   null);
        Storage.setValue("rank_crossing", event);

        // Wake Background in 5 s to upload + fetch rankings
        _triggerBackground(5);

        _state       = ST_RESULT;
        _resultTicks = 30;
        _nearest     = sign;
        var detFin = _detector;
        if (detFin != null) { (detFin as CrossingDetector).reset(); }
    }

    private function _loadSigns() as Array {
        var stored = Storage.getValue(SK_SIGNS);
        if (stored instanceof Array && (stored as Array).size() > 0) {
            return stored as Array;
        }
        return [] as Array;
    }

    // ─── Drawing ──────────────────────────────────────────────────────────────

    private function _stateLabel() as String {
        if (_state == ST_NO_GPS)   { return "GPS..."; }
        if (_state == ST_IDLE)     { return "Idle"; }
        if (_state == ST_APPROACH) { return "Approach"; }
        if (_state == ST_SPRINT)   { return "Sprint"; }
        if (_state == ST_RESULT)   { return "Result"; }
        return "?";
    }

    private function _drawIdle(dc as Graphics.Dc, w as Number, h as Number,
                                cx as Number, fg as Number, bg as Number) as Void {
        if (_signs.size() == 0) {
            _text(dc, cx, h / 3, Graphics.FONT_SMALL, "Lade Schilder...", Graphics.COLOR_DK_GRAY, bg);
            // Show how long until/since Background ran
            var bgTs    = Storage.getValue("bg_started");
            var bgFetch = Storage.getValue("bg_fetch_started");
            var line1   = "";
            var line2   = "";
            if (bgTs instanceof Number) {
                var age = Time.now().value() - (bgTs as Number);
                line1 = "BG lief vor " + age.toString() + "s";
                line2 = (bgFetch instanceof Number) ? "Anfrage gesendet" : "kein GPS";
            } else {
                line1 = "BG startet in ~5 min";
                line2 = "Handy verbinden!";
            }
            _text(dc, cx, h * 2 / 3,     Graphics.FONT_TINY, line1, Graphics.COLOR_DK_GRAY, bg);
            _text(dc, cx, h * 2 / 3 + 14, Graphics.FONT_TINY, line2, Graphics.COLOR_DK_GRAY, bg);
            return;
        }
        var sign    = _nearest;
        var name    = (sign != null) ? sign.get("name").toString() : "-";
        var dist    = _nearestDist;
        var distStr = (dist != null) ? _fmtDist(dist as Float) : "-";
        _text(dc, cx, h / 3,     Graphics.FONT_SMALL, name,    fg, bg);
        _text(dc, cx, h * 2 / 3, Graphics.FONT_LARGE, distStr, fg, bg);
    }

    private function _drawDistance(dc as Graphics.Dc, w as Number, h as Number, cx as Number,
                                    fg as Number, bg as Number, accent as Number) as Void {
        var sign    = _nearest;
        var name    = (sign != null) ? sign.get("name").toString() : "-";
        var dist    = _nearestDist;
        var distStr = (dist != null) ? _fmtDist(dist as Float) : "-";
        _text(dc, cx, h / 3,     Graphics.FONT_SMALL, name,    fg,     bg);
        _text(dc, cx, h * 2 / 3, Graphics.FONT_LARGE, distStr, accent, bg);
    }

    private function _drawResult(dc as Graphics.Dc, w as Number, h as Number,
                                  cx as Number, fg as Number, bg as Number) as Void {
        var sign = _nearest;
        var name = (sign != null) ? sign.get("name").toString() : "Ziel";
        _text(dc, cx, h / 8, Graphics.FONT_TINY, name, Graphics.COLOR_GREEN, bg);

        var myTs = _myTs;
        if (myTs == null) {
            _text(dc, cx, h * 2 / 5, Graphics.FONT_TINY, "Jemand da!", fg, bg);
            _drawServerRank(dc, h, cx, fg, bg);
            return;
        }

        var myTsNum = myTs as Number;
        var ldrTs   = _leaderTs;

        if (ldrTs == null || myTsNum <= (ldrTs as Number)) {
            _text(dc, cx, h * 2 / 5, Graphics.FONT_MEDIUM, "1. Platz!", Graphics.COLOR_GREEN, bg);
            if (ldrTs != null && (ldrTs as Number) > myTsNum) {
                var gapS = ((ldrTs as Number) - myTsNum).toFloat();
                _text(dc, cx, h * 3 / 5, Graphics.FONT_TINY,
                      "+" + gapS.format("%.1f") + "s dahinter", fg, bg);
            } else {
                _text(dc, cx, h * 3 / 5, Graphics.FONT_TINY,
                      "Warte auf Gruppe...", Graphics.COLOR_DK_GRAY, bg);
            }
        } else {
            var deltaS = (myTsNum - (ldrTs as Number)).toFloat();
            _text(dc, cx, h * 2 / 5, Graphics.FONT_MEDIUM,
                  "+" + deltaS.format("%.1f") + "s", Graphics.COLOR_YELLOW, bg);
            _text(dc, cx, h * 3 / 5, Graphics.FONT_TINY, "hinter Fuehrendem", fg, bg);
        }

        _drawServerRank(dc, h, cx, fg, bg);
    }

    private function _drawServerRank(dc as Graphics.Dc, h as Number,
                                      cx as Number, fg as Number, bg as Number) as Void {
        var line = "";
        var col  = Graphics.COLOR_DK_GRAY;
        if (_rankStatus == RS_LOADING) {
            line = "Server...";
        } else if (_rankStatus == RS_DONE) {
            if (_rankPos == 1) {
                line = "Bestzeit! (" + _rankTotal.toString() + " Fahrer)";
                col  = Graphics.COLOR_GREEN;
            } else {
                line = "Platz " + _rankPos.toString() + "/" + _rankTotal.toString() +
                       " +" + _rankDelta.format("%.1f") + "s";
                col  = (_rankPos <= 3) ? Graphics.COLOR_YELLOW : fg;
            }
        } else if (_rankStatus == RS_OFFLINE) {
            line = "Offline";
        }
        if (!line.equals("")) {
            _text(dc, cx, h * 7 / 8, Graphics.FONT_TINY, line, col, bg);
        }
    }

    private function _text(dc as Graphics.Dc, x as Number, y as Number,
                            font as Graphics.FontType, text as String,
                            fg as Number, bg as Number) as Void {
        dc.setColor(fg, bg);
        dc.drawText(x, y, font, text,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    private function _fmtDist(dist as Float) as String {
        if (dist >= 1000.0) {
            return (dist / 1000.0).format("%.1f") + " km";
        }
        return dist.format("%.0f") + " m";
    }
}
