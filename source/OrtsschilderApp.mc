import Toybox.Application;
import Toybox.Background;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.WatchUi;

// Entry point for the DataField app.
// - Live sprint results via ANT+ (no phone needed during ride)
// - Crossings uploaded to Supabase via Background service after the ride
(:background)
class OrtsschilderApp extends Application.AppBase {
    private var _field as OrtsschilderField?;

    public function initialize() {
        AppBase.initialize();
    }

    public function onStart(state as Dictionary?) as Void {
        try {
            // Fallback timer — DataField overrides this with a 5s trigger
            // as soon as the first GPS fix is acquired.
            Background.registerForTemporalEvent(
                Time.now().add(new Time.Duration(600))
            );
        } catch (e instanceof Lang.Exception) {}
    }

    public function onStop(state as Dictionary?) as Void {
        var f = _field;
        if (f != null) { f.onAntRelease(); }
    }

    public function getInitialView() as [Views] or [Views, InputDelegates] {
        _field = new $.OrtsschilderField();
        return [_field];
    }

    public function getServiceDelegate() as [ServiceDelegate] {
        return [new $.OrtsschilderBackground()];
    }

    public function onBackgroundData(data as PersistableType) as Void {
    }
}
