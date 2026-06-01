using Gst;
using Gdk;

namespace Singularity.Apps.Videos {

    /**
     * Thin wrapper around a GStreamer playbin pipeline.
     *
     * Handles pipeline state, seeking, and the GTK4 paintable sink.
     * The owner (PlayerWindow) drives the position-update timer.
     */
    public class GstPlayer : GLib.Object {

        private Gst.Element? _playbin;
        private uint         _bus_watch_id = 0;

        /** Fired on GStreamer pipeline error. */
        public signal void error_occurred (string message);

        /** The paintable to display in a Gtk.Picture (null if sink unavailable). */
        public Gdk.Paintable? paintable { get; private set; }

        /** False when playbin could not be created. */
        public bool valid { get { return _playbin != null; } }

        public GstPlayer () {
            _playbin = Gst.ElementFactory.make ("playbin", "playbin");
            if (_playbin == null) {
                warning ("GstPlayer: could not create GStreamer playbin");
                return;
            }

            var sink = Gst.ElementFactory.make ("gtk4paintablesink", "sink");
            if (sink != null) {
                _playbin.set ("video-sink", sink);
                Gdk.Paintable p;
                sink.get ("paintable", out p);
                paintable = p;
            } else {
                // CRITICAL: without gtk4paintablesink, playbin picks its
                // own default video sink (waylandsink/glimagesink/etc.) which
                // opens a SEPARATE floating window for the frames - exactly
                // what the user reported. Force fakesink so video frames are
                // dropped silently, and surface an actionable error so we can
                // tell the user to install gstreamer1.0-gtk4.
                warning ("GstPlayer: gtk4paintablesink not available - video won't render");
                var fake = Gst.ElementFactory.make ("fakesink", "sink");
                if (fake != null) _playbin.set ("video-sink", fake);
                // Schedule the error after construction so listeners exist.
                GLib.Idle.add (() => {
                    error_occurred (
                        "Video playback unavailable - install the gstreamer1.0-gtk4 "
                        + "package (provides gtk4paintablesink) and restart Videos.");
                    return GLib.Source.REMOVE;
                });
            }

            var bus = _playbin.get_bus ();
            _bus_watch_id = bus.add_watch (GLib.Priority.DEFAULT, _on_bus_message);
        }

        ~GstPlayer () {
            if (_bus_watch_id != 0) GLib.Source.remove (_bus_watch_id);
            if (_playbin != null) _playbin.set_state (Gst.State.NULL);
        }

        /** Open and immediately start playing a URI. */
        public void open (string uri) {
            if (_playbin == null) return;
            _playbin.set_state (Gst.State.NULL);
            _playbin.set ("uri", uri);
            var ret = _playbin.set_state (Gst.State.PLAYING);
            if (ret == Gst.StateChangeReturn.FAILURE)
                warning ("GstPlayer: failed to transition to PLAYING");
        }

        public void play () {
            _playbin?.set_state (Gst.State.PLAYING);
        }

        public void pause () {
            _playbin?.set_state (Gst.State.PAUSED);
        }

        public Gst.State current_state () {
            if (_playbin == null) return Gst.State.NULL;
            Gst.State cur, pending;
            _playbin.get_state (out cur, out pending, 0);
            return cur;
        }

        /** Seek to a position expressed as 0.0–100.0 percent of duration. */
        public void seek_to (double percent) {
            if (_playbin == null) return;
            int64 duration = -1;
            if (_playbin.query_duration (Gst.Format.TIME, out duration) && duration > 0) {
                int64 pos = (int64) (percent / 100.0 * duration);
                _playbin.seek_simple (Gst.Format.TIME,
                    Gst.SeekFlags.FLUSH | Gst.SeekFlags.KEY_UNIT, pos);
            }
        }

        public void skip (int64 nanoseconds) {
            if (_playbin == null) return;
            int64 pos = 0, dur = 0;
            _playbin.query_position (Gst.Format.TIME, out pos);
            _playbin.query_duration (Gst.Format.TIME, out dur);
            int64 target = pos + nanoseconds;
            if (nanoseconds > 0 && dur > 0) target = int64.min (dur, target);
            if (nanoseconds < 0)            target = int64.max (0, target);
            _playbin.seek_simple (Gst.Format.TIME,
                Gst.SeekFlags.FLUSH | Gst.SeekFlags.KEY_UNIT, target);
        }

        /** Returns current playback position as 0.0–100.0 percent (0 if unknown). */
        public double position_percent () {
            if (_playbin == null) return 0.0;
            int64 pos = 0, dur = 0;
            if (_playbin.query_position (Gst.Format.TIME, out pos) &&
                _playbin.query_duration (Gst.Format.TIME, out dur) && dur > 0)
                return (double) pos / (double) dur * 100.0;
            return 0.0;
        }

        private bool _on_bus_message (Gst.Bus bus, Gst.Message msg) {
            if (msg.type == Gst.MessageType.ERROR) {
                GLib.Error err; string debug;
                msg.parse_error (out err, out debug);
                error_occurred (err.message);
            }
            return true;
        }
    }
}
