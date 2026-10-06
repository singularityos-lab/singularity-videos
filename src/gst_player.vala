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

            var video = new Singularity.Widgets.VideoPaintable ();
            if (video.sink != null) {
                _playbin.set ("video-sink", video.sink);
                paintable = video;
            } else {
                warning ("GstPlayer: no usable video sink - video won't render");
                var fake = Gst.ElementFactory.make ("fakesink", "sink");
                if (fake != null) _playbin.set ("video-sink", fake);
                GLib.Idle.add (() => {
                    error_occurred (
                        "Video playback unavailable - the GStreamer videoconvert "
                        + "and appsink elements are missing.");
                    return GLib.Source.REMOVE;
                });
            }

            var bus = _playbin.get_bus ();
            _bus_watch_id = bus.add_watch (GLib.Priority.DEFAULT, _on_bus_message);
            GLib.Signal.connect (_playbin, "source-setup", (GLib.Callback) _on_source_setup, this);
        }

        private GLib.HashTable<string, string>? _headers = null;

        public void set_http_headers (GLib.HashTable<string, string>? headers) {
            _headers = headers;
        }

        private static void _on_source_setup (Gst.Element playbin, Gst.Element source, GstPlayer self) {
            if (self._headers == null || self._headers.size () == 0) return;
            var klass = (GLib.ObjectClass) source.get_type ().class_ref ();
            var extra = new Gst.Structure.empty ("extra-headers");
            self._headers.foreach ((k, v) => {
                if (k.down () == "user-agent" && klass.find_property ("user-agent") != null) {
                    source.set ("user-agent", v);
                    return;
                }
                extra.set_value (k, v);
            });
            if (klass.find_property ("extra-headers") != null && extra.n_fields () > 0) source.set ("extra-headers", extra);
        }

        ~GstPlayer () {
            if (_bus_watch_id != 0) GLib.Source.remove (_bus_watch_id);
            if (_playbin != null) _playbin.set_state (Gst.State.NULL);
        }

        /** Open and immediately start playing a URI. */
        public void open (string uri) {
            if (_playbin == null) return;
            _playbin.set_state (Gst.State.NULL);
            _rate = 1.0;
            _playbin.set ("uri", uri);
            var ret = _playbin.set_state (Gst.State.PLAYING);
            if (ret == Gst.StateChangeReturn.FAILURE)
                warning ("GstPlayer: failed to transition to PLAYING");
        }

        public void open_paused (string uri) {
            if (_playbin == null) return;
            _playbin.set_state (Gst.State.NULL);
            _rate = 1.0;
            _playbin.set ("uri", uri);
            if (_playbin.set_state (Gst.State.PAUSED) == Gst.StateChangeReturn.FAILURE)
                warning ("GstPlayer: failed to transition to PAUSED");
        }

        public void close () {
            _playbin?.set_state (Gst.State.NULL);
        }

        public void play () {
            _playbin?.set_state (Gst.State.PLAYING);
        }

        public void pause () {
            _playbin?.set_state (Gst.State.PAUSED);
        }

        public double volume {
            get {
                double v = 1.0;
                if (_playbin != null) _playbin.get ("volume", out v);
                return v;
            }
            set {
                _playbin?.set ("volume", value.clamp (0.0, 1.0));
            }
        }

        public bool muted {
            get {
                bool m = false;
                if (_playbin != null) _playbin.get ("mute", out m);
                return m;
            }
            set {
                _playbin?.set ("mute", value);
            }
        }

        public Gst.State current_state () {
            if (_playbin == null) return Gst.State.NULL;
            Gst.State cur, pending;
            _playbin.get_state (out cur, out pending, 0);
            return cur;
        }

        /** Seeks to a position expressed as a percentage (0 to 100) of the duration. */
        public void seek_to (double percent) {
            if (_playbin == null) return;
            int64 duration = -1;
            if (_playbin.query_duration (Gst.Format.TIME, out duration) && duration > 0)
                _seek ((int64) (percent / 100.0 * duration), true);
        }

        /** Seeks by a relative offset, clamped to the stream bounds. */
        public void skip (int64 nanoseconds) {
            if (_playbin == null) return;
            int64 pos = 0, dur = 0;
            _playbin.query_position (Gst.Format.TIME, out pos);
            _playbin.query_duration (Gst.Format.TIME, out dur);
            int64 target = pos + nanoseconds;
            if (nanoseconds > 0 && dur > 0) target = int64.min (dur, target);
            if (nanoseconds < 0)            target = int64.max (0, target);
            _seek (target, true);
        }

        /**
         * Seeks to an absolute position.
         *
         * A fast seek lands on the nearest key frame, which suits live
         * scrubbing; otherwise the seek is frame accurate.
         */
        public void seek_ns_fast (int64 position, bool fast) {
            _seek (int64.max (0, position), !fast);
        }

        /** Playback speed, where 1.0 is normal speed. */
        public double rate {
            get { return _rate; }
            set {
                double r = value.clamp (0.25, 4.0);
                if (r == _rate) return;
                _rate = r;
                int64 pos = 0;
                if (_playbin != null && _playbin.query_position (Gst.Format.TIME, out pos))
                    _seek (pos, true);
            }
        }

        /**
         * Fraction of the stream buffered from the start, or -1 when the
         * pipeline does not report it.
         */
        public double buffered_fraction () {
            if (_playbin == null) return -1;
            var query = new Gst.Query.buffering (Gst.Format.PERCENT);
            if (!_playbin.query (query)) return -1;
            Gst.Format format;
            int64 start, stop, estimated;
            query.parse_buffering_range (out format, out start, out stop, out estimated);
            if (format != Gst.Format.PERCENT || stop < 0) return -1;
            return ((double) stop / Gst.FORMAT_PERCENT_MAX).clamp (0.0, 1.0);
        }

        /** Emitted once the stream is ready and its tracks are known. */
        public signal void tracks_changed ();

        /** Readable names of the audio tracks. */
        public string[] audio_tracks () {
            return _track_names ("n-audio", "get-audio-tags");
        }

        /** Readable names of the subtitle tracks. */
        public string[] subtitle_tracks () {
            return _track_names ("n-text", "get-text-tags");
        }

        /** Index of the playing audio track. */
        public int current_audio {
            get {
                int i = 0;
                if (_playbin != null) _playbin.get ("current-audio", out i);
                return i;
            }
            set {
                _playbin?.set ("current-audio", value);
            }
        }

        /** Index of the shown subtitle track, or -1 when subtitles are off. */
        public int current_subtitle {
            get {
                if (_playbin == null) return -1;
                uint flags = 0;
                int i = -1;
                _playbin.get ("flags", out flags);
                if ((flags & PLAY_FLAG_TEXT) == 0) return -1;
                _playbin.get ("current-text", out i);
                return i;
            }
            set {
                if (_playbin == null) return;
                uint flags = 0;
                _playbin.get ("flags", out flags);
                if (value < 0) {
                    _playbin.set ("flags", flags & ~PLAY_FLAG_TEXT);
                } else {
                    _playbin.set ("flags", flags | PLAY_FLAG_TEXT);
                    _playbin.set ("current-text", value);
                }
            }
        }

        private const uint PLAY_FLAG_TEXT = 1 << 2;
        private double _rate = 1.0;

        private string[] _track_names (string count_prop, string tags_signal) {
            string[] names = {};
            if (_playbin == null) return names;
            int n = 0;
            _playbin.get (count_prop, out n);
            for (int i = 0; i < n; i++) {
                Gst.TagList? tags = null;
                GLib.Signal.emit_by_name (_playbin, tags_signal, i, out tags);
                string? title = null, lang = null;
                if (tags != null) {
                    tags.get_string (Gst.Tags.TITLE, out title);
                    if (!tags.get_string (Gst.Tags.LANGUAGE_NAME, out lang))
                        tags.get_string (Gst.Tags.LANGUAGE_CODE, out lang);
                }
                bool has_title = title != null && title != "";
                bool has_lang = lang != null && lang != "";
                if (has_title && has_lang) names += "%s (%s)".printf (title, _language_label (lang));
                else if (has_title) names += title;
                else if (has_lang) names += _language_label (lang);
                else names += _("Track %d").printf (i + 1);
            }
            return names;
        }

        private static string _language_label (string code) {
            return code.length > 3 ? code : code.up ();
        }

        private void _seek (int64 position, bool accurate) {
            if (_playbin == null) return;
            var flags = Gst.SeekFlags.FLUSH;
            flags |= accurate ? Gst.SeekFlags.ACCURATE : Gst.SeekFlags.KEY_UNIT | Gst.SeekFlags.SNAP_NEAREST;
            _playbin.seek (_rate, Gst.Format.TIME, flags,
                Gst.SeekType.SET, position, Gst.SeekType.NONE, (int64) Gst.CLOCK_TIME_NONE);
        }

        /** Returns the playback position as a percentage (0 to 100), or 0 if unknown. */
        public double position_percent () {
            if (_playbin == null) return 0.0;
            int64 pos = 0, dur = 0;
            if (_playbin.query_position (Gst.Format.TIME, out pos) &&
                _playbin.query_duration (Gst.Format.TIME, out dur) && dur > 0)
                return (double) pos / (double) dur * 100.0;
            return 0.0;
        }

        public signal void finished ();

        public int64 position_ns () {
            int64 pos = 0;
            if (_playbin != null && _playbin.query_position (Gst.Format.TIME, out pos)) return pos;
            return 0;
        }

        public int64 duration_ns () {
            int64 dur = 0;
            if (_playbin != null && _playbin.query_duration (Gst.Format.TIME, out dur)) return dur;
            return 0;
        }

        public void seek_ns (int64 position) {
            _seek (int64.max (0, position), true);
        }

        private bool _on_bus_message (Gst.Bus bus, Gst.Message msg) {
            if (msg.type == Gst.MessageType.EOS) finished ();
            if (msg.type == Gst.MessageType.ASYNC_DONE) tracks_changed ();
            if (msg.type == Gst.MessageType.ERROR) {
                GLib.Error err; string debug;
                msg.parse_error (out err, out debug);
                error_occurred (err.message);
            }
            return true;
        }
    }
}
