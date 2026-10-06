namespace Singularity.Apps.Videos {

    public class MediaStrip : GLib.Object {

        public const int THUMB_HEIGHT = 72;
        public const int PEAKS_PER_SECOND = 50;

        public string uri { get; construct; }
        public int64 duration { get; construct; }

        public signal void thumbnail_ready (int index, Gdk.Texture texture);
        public signal void waveform_ready ();

        private float[] _peaks = {};

        public unowned float[] peaks () {
            return _peaks;
        }
        public int thumbnail_count { get; private set; default = 0; }

        private Gdk.Texture?[] _thumbs = {};
        private int _stopped = 0;

        public MediaStrip (string uri, int64 duration) {
            GLib.Object (uri: uri, duration: duration);
        }

        public Gdk.Texture? thumbnail (int index) {
            if (index < 0 || index >= _thumbs.length) return null;
            return _thumbs[index];
        }

        public void stop () {
            GLib.AtomicInt.set (ref _stopped, 1);
        }

        private bool _is_stopped () {
            return GLib.AtomicInt.get (ref _stopped) != 0;
        }

        public void load (int thumbnails, bool has_video, bool has_audio) {
            thumbnail_count = has_video ? int.max (1, thumbnails) : 0;
            _thumbs = new Gdk.Texture?[thumbnail_count];
            if (has_video) {
                new GLib.Thread<bool> ("videos-thumbs", () => {
                    _extract_frames ();
                    return true;
                });
            }
            if (has_audio) {
                new GLib.Thread<bool> ("videos-wave", () => {
                    _extract_waveform ();
                    return true;
                });
            }
        }

        private void _extract_frames () {
            Gst.Element pipeline;
            try {
                pipeline = Gst.parse_launch (
                    "uridecodebin name=src expose-all-streams=false ! videoconvert ! videoscale "
                    + "! video/x-raw,format=RGBA,height=%d,pixel-aspect-ratio=1/1 ".printf (THUMB_HEIGHT)
                    + "! appsink name=sink sync=false max-buffers=1");
            } catch (GLib.Error e) {
                warning ("videos: thumbnails unavailable: %s", e.message);
                return;
            }
            var bin = (Gst.Bin) pipeline;
            var src = bin.get_by_name ("src");
            src.set ("uri", uri);
            src.set ("caps", Gst.Caps.from_string ("video/x-raw(ANY)"));
            var sink = (Gst.App.Sink) bin.get_by_name ("sink");
            pipeline.set_state (Gst.State.PAUSED);
            Gst.State state, pending;
            if (pipeline.get_state (out state, out pending, 20 * Gst.SECOND) == Gst.StateChangeReturn.FAILURE) {
                pipeline.set_state (Gst.State.NULL);
                return;
            }
            for (int i = 0; i < thumbnail_count && !_is_stopped (); i++) {
                int64 t = (int64) ((i + 0.5) * duration / thumbnail_count);
                pipeline.seek_simple (Gst.Format.TIME, Gst.SeekFlags.FLUSH | Gst.SeekFlags.ACCURATE, t);
                pipeline.get_state (out state, out pending, 10 * Gst.SECOND);
                var sample = sink.try_pull_preroll (5 * Gst.SECOND);
                if (sample == null) continue;
                var texture = _texture (sample);
                if (texture == null) continue;
                int index = i;
                GLib.Idle.add (() => {
                    if (index < _thumbs.length) _thumbs[index] = texture;
                    thumbnail_ready (index, texture);
                    return GLib.Source.REMOVE;
                });
            }
            pipeline.set_state (Gst.State.NULL);
        }

        private static Gdk.Texture? _texture (Gst.Sample sample) {
            unowned Gst.Caps? caps = sample.get_caps ();
            unowned Gst.Buffer? buffer = sample.get_buffer ();
            if (caps == null || buffer == null) return null;
            var info = new Gst.Video.Info ();
            if (!info.from_caps (caps)) return null;
            Gst.MapInfo map;
            if (!buffer.map (out map, Gst.MapFlags.READ)) return null;
            int stride = info.stride[0];
            int height = info.height;
            var bytes = new GLib.Bytes (map.data[0:stride * height]);
            buffer.unmap (map);
            return new Gdk.MemoryTexture (info.width, height, Gdk.MemoryFormat.R8G8B8A8, bytes, stride);
        }

        private void _extract_waveform () {
            Gst.Element pipeline;
            try {
                pipeline = Gst.parse_launch (
                    "uridecodebin name=src expose-all-streams=false ! audioconvert ! audioresample "
                    + "! audio/x-raw,format=F32LE,channels=1,rate=8000 ! appsink name=sink sync=false");
            } catch (GLib.Error e) {
                warning ("videos: waveform unavailable: %s", e.message);
                return;
            }
            var bin = (Gst.Bin) pipeline;
            var src = bin.get_by_name ("src");
            src.set ("uri", uri);
            src.set ("caps", Gst.Caps.from_string ("audio/x-raw(ANY)"));
            var sink = (Gst.App.Sink) bin.get_by_name ("sink");
            int buckets = int.max (1, (int) (duration * PEAKS_PER_SECOND / NS_PER_SECOND));
            var values = new float[buckets];
            int per_bucket = 8000 / PEAKS_PER_SECOND;
            int64 sample_index = 0;
            pipeline.set_state (Gst.State.PLAYING);
            while (!_is_stopped ()) {
                var sample = sink.try_pull_sample (5 * Gst.SECOND);
                if (sample == null) break;
                unowned Gst.Buffer buffer = sample.get_buffer ();
                if (buffer.pts != Gst.CLOCK_TIME_NONE)
                    sample_index = (int64) (buffer.pts * 8000 / Gst.SECOND);
                Gst.MapInfo map;
                if (!buffer.map (out map, Gst.MapFlags.READ)) continue;
                unowned float[] data = (float[]) map.data;
                int n = (int) (map.size / sizeof (float));
                for (int i = 0; i < n; i++) {
                    int bucket = (int) ((sample_index + i) / per_bucket);
                    if (bucket >= buckets) break;
                    float v = data[i].abs ();
                    if (v > values[bucket]) values[bucket] = v;
                }
                sample_index += n;
                buffer.unmap (map);
            }
            pipeline.set_state (Gst.State.NULL);
            if (_is_stopped ()) return;
            GLib.Idle.add (() => {
                _peaks = values;
                waveform_ready ();
                return GLib.Source.REMOVE;
            });
        }
    }
}
