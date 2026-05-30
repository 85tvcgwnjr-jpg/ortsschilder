import Toybox.Ant;
import Toybox.Lang;

// Hashes a String to a 16-bit value for use in ANT payloads.
function hashStr(s as String) as Number {
    var h = 0;
    var ca = s.toCharArray();
    for (var i = 0; i < ca.size(); i++) {
        h = (h * 31 + ca[i].toNumber()) & 0xFFFF;
    }
    return h;
}

// Peer-to-peer ANT+ communication between Garmin devices.
//
// Protocol: 8-byte broadcast
//   [signHi, signLo, devHi, devLo, tsB3, tsB2, tsB1, tsB0]
//
// Each device keeps a SLAVE channel open at all times.
// When a crossing is detected the device additionally opens a MASTER
// channel and broadcasts for BCAST_SECS seconds.
class OrtsschilderAnt {

    private const DEVICE_TYPE = 0x4F as Number; // 'O' — custom Ortsschild profile
    private const RF_FREQ     = 66   as Number; // 2.466 GHz (outside standard ANT+ bands)
    private const MSG_PERIOD  = 8192 as Number; // ~4 Hz
    private const BCAST_SECS  = 30   as Number;

    private var _slave   as Ant.GenericChannel?;
    private var _master  as Ant.GenericChannel?;
    private var _msg     as Ant.Message           = new Ant.Message();
    private var _payload as Array<Number>         = new Array<Number>[8];
    private var _txUntil as Number                = 0;
    private var _onRx    as Method;

    function initialize(onRxCallback as Method) {
        _onRx = onRxCallback;
        for (var i = 0; i < 8; i++) { _payload[i] = 0; }
        _openSlave();
    }

    // Call once per second from compute() to drive master broadcast timing.
    function tick(nowSec as Number) as Void {
        var m = _master;
        if (m == null) { return; }
        if (nowSec < _txUntil) {
            _send(m);
        } else {
            _closeMaster();
        }
    }

    // Call when own sign crossing is detected.
    function broadcastCrossing(signHash as Number, devHash as Number,
                               tsSec as Number, nowSec as Number) as Void {
        _payload[0] = (signHash >> 8) & 0xFF;
        _payload[1] =  signHash       & 0xFF;
        _payload[2] = (devHash  >> 8) & 0xFF;
        _payload[3] =  devHash        & 0xFF;
        _payload[4] = (tsSec >> 24)   & 0xFF;
        _payload[5] = (tsSec >> 16)   & 0xFF;
        _payload[6] = (tsSec >>  8)   & 0xFF;
        _payload[7] =  tsSec          & 0xFF;
        _txUntil = nowSec + BCAST_SECS;
        _openMaster(devHash);
        var m = _master;
        if (m != null) { _send(m); }
    }

    function release() as Void {
        _closeSlave();
        _closeMaster();
    }

    // ─── ANT callbacks ────────────────────────────────────────────────────────

    public function onSlaveMessage(msg as Ant.Message) as Void {
        var p = msg.getPayload();
        if (p == null) { return; }
        var a = p as Array<Number>;
        if (a.size() < 8) { return; }
        var signHash = ((a[0]) << 8) | (a[1]);
        var devHash  = ((a[2]) << 8) | (a[3]);
        var ts       = ((a[4]) << 24) | ((a[5]) << 16) | ((a[6]) << 8) | (a[7]);
        _onRx.invoke(signHash, devHash, ts);
    }

    public function onMasterMessage(msg as Ant.Message) as Void {
        // No-op for broadcast master.
    }

    // ─── Private ──────────────────────────────────────────────────────────────

    private function _send(ch as Ant.GenericChannel) as Void {
        try {
            _msg.setPayload(_payload);
            ch.sendBroadcast(_msg);
        } catch (e instanceof Lang.Exception) {}
    }

    private function _openSlave() as Void {
        try {
            var ca  = new Ant.ChannelAssignment(Ant.CHANNEL_TYPE_RX_NOT_TX, Ant.NETWORK_PLUS);
            var cfg = new Ant.DeviceConfig({
                :deviceNumber              => 0,
                :deviceType                => DEVICE_TYPE,
                :transmissionType          => 0,
                :messagePeriod             => MSG_PERIOD,
                :radioFrequency            => RF_FREQ,
                :searchTimeoutLowPriority  => 2,
                :searchTimeoutHighPriority => 0
            });
            var ch = new Ant.GenericChannel(method(:onSlaveMessage), ca);
            ch.setDeviceConfig(cfg);
            ch.open();
            _slave = ch;
        } catch (e instanceof Lang.Exception) {}
    }

    private function _openMaster(devHash as Number) as Void {
        if (_master != null) { return; }
        try {
            var ca  = new Ant.ChannelAssignment(Ant.CHANNEL_TYPE_TX_NOT_RX, Ant.NETWORK_PLUS);
            var cfg = new Ant.DeviceConfig({
                :deviceNumber     => devHash & 0xFFFF,
                :deviceType       => DEVICE_TYPE,
                :transmissionType => 1,
                :messagePeriod    => MSG_PERIOD,
                :radioFrequency   => RF_FREQ
            });
            var ch = new Ant.GenericChannel(method(:onMasterMessage), ca);
            ch.setDeviceConfig(cfg);
            ch.open();
            _master = ch;
        } catch (e instanceof Lang.Exception) {}
    }

    private function _closeSlave() as Void {
        var s = _slave;
        if (s != null) {
            try { s.release(); } catch (e instanceof Lang.Exception) {}
            _slave = null;
        }
    }

    private function _closeMaster() as Void {
        var m = _master;
        if (m != null) {
            try { m.release(); } catch (e instanceof Lang.Exception) {}
            _master = null;
        }
    }
}
