namespace Singularity.Apps.Videos {

    public const int64 NS_PER_SECOND = 1000000000;

    public struct TimeRange {
        public int64 start;
        public int64 end;

        public TimeRange (int64 start, int64 end) {
            this.start = int64.min (start, end);
            this.end = int64.max (start, end);
        }

        public int64 length () {
            return end - start;
        }

        public bool contains (int64 t) {
            return t >= start && t < end;
        }
    }

    public class Segment : GLib.Object {
        public int clip_index { get; construct; }
        public string uri { get; construct; }
        public int64 start { get; construct; }
        public int64 end { get; construct; }
        public int64 output_offset { get; construct; }

        public Segment (int clip_index, string uri, int64 start, int64 end, int64 output_offset) {
            GLib.Object (clip_index: clip_index, uri: uri, start: start, end: end, output_offset: output_offset);
        }

        public int64 length () {
            return end - start;
        }
    }

    public class EditClip : GLib.Object {
        public string uri { get; construct; }
        public int64 duration { get; construct; }
        public int width { get; set; default = 0; }
        public int height { get; set; default = 0; }
        public int storage_width { get; set; default = 0; }
        public int fps_n { get; set; default = 30; }
        public int fps_d { get; set; default = 1; }
        public bool has_video { get; set; default = true; }
        public bool has_audio { get; set; default = true; }
        public int64 in_point { get; private set; default = 0; }
        public int64 out_point { get; private set; }

        private TimeRange[] _cuts = {};

        public EditClip (string uri, int64 duration) {
            GLib.Object (uri: uri, duration: int64.max (0, duration));
            out_point = this.duration;
        }

        public int pixel_width () {
            return storage_width > 0 ? storage_width : width;
        }

        public string display_name () {
            string base_name = GLib.Path.get_basename (GLib.Uri.unescape_string (uri) ?? uri);
            return base_name != "" ? base_name : uri;
        }

        public int64 frame_duration () {
            if (fps_n <= 0 || fps_d <= 0) return NS_PER_SECOND / 30;
            return (int64) ((double) NS_PER_SECOND * fps_d / fps_n);
        }

        public int64 snap (int64 t) {
            if (fps_n <= 0 || fps_d <= 0) return t.clamp (0, duration);
            double frames = Math.round ((double) t * fps_n / ((double) NS_PER_SECOND * fps_d));
            int64 snapped = (int64) Math.round (frames * NS_PER_SECOND * fps_d / fps_n);
            return snapped.clamp (0, duration);
        }

        public int64 frame_at (int64 t) {
            if (fps_n <= 0 || fps_d <= 0) return 0;
            return (int64) Math.floor ((double) t * fps_n / ((double) NS_PER_SECOND * fps_d) + 1e-6);
        }

        public void set_trim (int64 in_ns, int64 out_ns) {
            int64 a = in_ns.clamp (0, duration);
            int64 b = out_ns.clamp (0, duration);
            if (b < a) {
                int64 t = a;
                a = b;
                b = t;
            }
            in_point = a;
            out_point = b;
        }

        public void reset_trim () {
            in_point = 0;
            out_point = duration;
        }

        public void add_cut (int64 start, int64 end) {
            var range = TimeRange (start.clamp (0, duration), end.clamp (0, duration));
            if (range.length () <= 0) return;
            TimeRange[] merged = {};
            foreach (var c in _cuts) {
                if (c.end < range.start || c.start > range.end) {
                    merged += c;
                } else {
                    range = TimeRange (int64.min (c.start, range.start), int64.max (c.end, range.end));
                }
            }
            merged += range;
            _sort (merged);
            _cuts = merged;
        }

        public bool remove_cut_at (int64 t) {
            TimeRange[] kept = {};
            bool removed = false;
            foreach (var c in _cuts) {
                if (!removed && c.contains (t)) {
                    removed = true;
                    continue;
                }
                kept += c;
            }
            _cuts = kept;
            return removed;
        }

        public void clear_cuts () {
            _cuts = {};
        }

        public TimeRange[] cuts () {
            return _cuts;
        }

        public TimeRange? cut_at (int64 t) {
            foreach (var c in _cuts) {
                if (c.contains (t)) return c;
            }
            return null;
        }

        public TimeRange[] kept_ranges () {
            TimeRange[] out_ranges = {};
            int64 cursor = in_point;
            foreach (var c in _cuts) {
                int64 cs = c.start.clamp (in_point, out_point);
                int64 ce = c.end.clamp (in_point, out_point);
                if (ce <= cs) continue;
                if (cs > cursor) out_ranges += TimeRange (cursor, cs);
                cursor = int64.max (cursor, ce);
            }
            if (out_point > cursor) out_ranges += TimeRange (cursor, out_point);
            return out_ranges;
        }

        public int64 kept_duration () {
            int64 total = 0;
            foreach (var r in kept_ranges ()) total += r.length ();
            return total;
        }

        public bool is_kept (int64 t) {
            foreach (var r in kept_ranges ()) {
                if (r.contains (t)) return true;
            }
            return false;
        }

        public int64 next_kept (int64 t) {
            foreach (var r in kept_ranges ()) {
                if (t < r.start) return r.start;
                if (r.contains (t)) return t;
            }
            return -1;
        }

        private static void _sort (TimeRange[] ranges) {
            for (int i = 1; i < ranges.length; i++) {
                var key = ranges[i];
                int j = i - 1;
                while (j >= 0 && ranges[j].start > key.start) {
                    ranges[j + 1] = ranges[j];
                    j--;
                }
                ranges[j + 1] = key;
            }
        }
    }

    public class EditList : GLib.Object {

        public signal void changed ();

        public int rotation {
            get { return _rotation; }
        }

        private int _rotation = 0;
        public CropBox crop {
            get { return _crop; }
        }

        private CropBox _crop = new CropBox ();

        private Gee.ArrayList<EditClip> _clips = new Gee.ArrayList<EditClip> ();

        public int size {
            get { return _clips.size; }
        }

        public EditClip get_clip (int index) {
            return _clips[index];
        }

        public void add (EditClip clip) {
            _clips.add (clip);
            changed ();
        }

        public void reset () {
            _clips.clear ();
            _rotation = 0;
            _crop = new CropBox ();
            changed ();
        }

        public void remove_at (int index) {
            if (index < 0 || index >= _clips.size) return;
            _clips.remove_at (index);
            changed ();
        }

        public bool move (int from, int to) {
            if (from < 0 || from >= _clips.size || to < 0 || to >= _clips.size || from == to) return false;
            var clip = _clips.remove_at (from);
            _clips.insert (to, clip);
            changed ();
            return true;
        }

        public void set_rotation (int quarter_turns) {
            int turns = ((quarter_turns % 4) + 4) % 4;
            if (turns == _rotation) return;
            int delta = ((turns - _rotation) % 4 + 4) % 4;
            _crop = _crop.rotated (delta);
            _rotation = turns;
            changed ();
        }

        public void rotate_by (int quarter_turns) {
            set_rotation (rotation + quarter_turns);
        }

        public void set_crop (CropBox box) {
            _crop = box.normalized ();
            changed ();
        }

        public void notify_changed () {
            changed ();
        }

        public Segment[] segments () {
            Segment[] result = {};
            int64 offset = 0;
            for (int i = 0; i < _clips.size; i++) {
                var clip = _clips[i];
                foreach (var r in clip.kept_ranges ()) {
                    if (r.length () <= 0) continue;
                    result += new Segment (i, clip.uri, r.start, r.end, offset);
                    offset += r.length ();
                }
            }
            return result;
        }

        public int64 output_duration () {
            int64 total = 0;
            foreach (var clip in _clips) total += clip.kept_duration ();
            return total;
        }

        public int64 source_duration () {
            int64 total = 0;
            foreach (var clip in _clips) total += clip.duration;
            return total;
        }

        public int64 clip_offset (int index) {
            int64 total = 0;
            for (int i = 0; i < index && i < _clips.size; i++) total += _clips[i].duration;
            return total;
        }

        public int clip_at (int64 sequence_time, out int64 local) {
            int64 cursor = 0;
            for (int i = 0; i < _clips.size; i++) {
                int64 d = _clips[i].duration;
                if (sequence_time < cursor + d || i == _clips.size - 1) {
                    local = (sequence_time - cursor).clamp (0, d);
                    return i;
                }
                cursor += d;
            }
            local = 0;
            return -1;
        }

        public int64 output_position (int index, int64 local) {
            int64 total = 0;
            for (int i = 0; i < index && i < _clips.size; i++) total += _clips[i].kept_duration ();
            if (index < 0 || index >= _clips.size) return total;
            foreach (var r in _clips[index].kept_ranges ()) {
                if (local >= r.end) total += r.length ();
                else if (local > r.start) total += local - r.start;
            }
            return total;
        }

        public void source_size (out int width, out int height) {
            width = 0;
            height = 0;
            foreach (var clip in _clips) {
                if (clip.has_video && clip.width > 0 && clip.height > 0) {
                    width = clip.width;
                    height = clip.height;
                    return;
                }
            }
        }

        public void output_framerate (out int fps_n, out int fps_d) {
            fps_n = 30;
            fps_d = 1;
            foreach (var clip in _clips) {
                if (clip.has_video && clip.fps_n > 0 && clip.fps_d > 0) {
                    double fps = (double) clip.fps_n / clip.fps_d;
                    if (fps > 60.5) {
                        fps_n = 60;
                        fps_d = 1;
                    } else {
                        fps_n = clip.fps_n;
                        fps_d = clip.fps_d;
                    }
                    return;
                }
            }
        }

        public void output_size (ExportPreset preset, out int width, out int height) {
            int w, h;
            source_size (out w, out h);
            if (w <= 0 || h <= 0) {
                w = 1280;
                h = 720;
            }
            Geometry.output_size (w, h, rotation, crop, preset.max_long_side (), preset.max_short_side (),
                                  out width, out height);
        }
    }

    public class CropBox : GLib.Object {
        public const double MIN_SIZE = 0.05;

        public double left { get; construct; }
        public double top { get; construct; }
        public double right { get; construct; }
        public double bottom { get; construct; }

        public CropBox (double left = 0, double top = 0, double right = 0, double bottom = 0) {
            GLib.Object (left: left, top: top, right: right, bottom: bottom);
        }

        public bool is_identity () {
            return left <= 0.0005 && top <= 0.0005 && right <= 0.0005 && bottom <= 0.0005;
        }

        public double width_fraction () {
            return 1.0 - left - right;
        }

        public double height_fraction () {
            return 1.0 - top - bottom;
        }

        public CropBox normalized () {
            double l = left.clamp (0, 1 - MIN_SIZE);
            double t = top.clamp (0, 1 - MIN_SIZE);
            double r = right.clamp (0, 1 - MIN_SIZE - l);
            double b = bottom.clamp (0, 1 - MIN_SIZE - t);
            return new CropBox (l, t, r, b);
        }

        public CropBox rotated (int quarter_turns) {
            int turns = ((quarter_turns % 4) + 4) % 4;
            double l = left, t = top, r = right, b = bottom;
            for (int i = 0; i < turns; i++) {
                double nl = b, nt = l, nr = t, nb = r;
                l = nl;
                t = nt;
                r = nr;
                b = nb;
            }
            return new CropBox (l, t, r, b);
        }

        public void pixels (int frame_width, int frame_height, out int l, out int t, out int r, out int b) {
            l = _even ((int) Math.round (left * frame_width));
            t = _even ((int) Math.round (top * frame_height));
            r = _even ((int) Math.round (right * frame_width));
            b = _even ((int) Math.round (bottom * frame_height));
            if (frame_width - l - r < 2) r = int.max (0, frame_width - l - 2);
            if (frame_height - t - b < 2) b = int.max (0, frame_height - t - 2);
        }

        public static CropBox with_aspect (double aspect, int frame_width, int frame_height) {
            if (aspect <= 0 || frame_width <= 0 || frame_height <= 0) return new CropBox ();
            double fw = frame_width, fh = frame_height;
            double w = fw, h = fw / aspect;
            if (h > fh) {
                h = fh;
                w = fh * aspect;
            }
            double lx = (fw - w) / 2.0 / fw;
            double ty = (fh - h) / 2.0 / fh;
            return new CropBox (lx, ty, lx, ty);
        }

        private static int _even (int v) {
            return v - (v % 2);
        }
    }

    namespace Geometry {

        public void rotated_size (int width, int height, int rotation, out int rw, out int rh) {
            bool swap = (((rotation % 4) + 4) % 4) % 2 == 1;
            rw = swap ? height : width;
            rh = swap ? width : height;
        }

        public void cropped_size (int width, int height, int rotation, CropBox crop, out int cw, out int ch) {
            int rw, rh;
            rotated_size (width, height, rotation, out rw, out rh);
            int l, t, r, b;
            crop.pixels (rw, rh, out l, out t, out r, out b);
            cw = rw - l - r;
            ch = rh - t - b;
        }

        public void output_size (int width, int height, int rotation, CropBox crop, int max_long, int max_short,
                                 out int ow, out int oh) {
            int cw, ch;
            cropped_size (width, height, rotation, crop, out cw, out ch);
            double scale = 1.0;
            if (max_long > 0 && max_short > 0) {
                if (cw >= ch) scale = double.min (1.0, double.min ((double) max_long / cw, (double) max_short / ch));
                else scale = double.min (1.0, double.min ((double) max_short / cw, (double) max_long / ch));
            }
            ow = int.max (2, _even_round (cw * scale));
            oh = int.max (2, _even_round (ch * scale));
        }

        public string flip_method (int rotation) {
            switch (((rotation % 4) + 4) % 4) {
                case 1: return "clockwise";
                case 2: return "rotate-180";
                case 3: return "counterclockwise";
                default: return "none";
            }
        }

        private int _even_round (double v) {
            return (int) Math.round (v / 2.0) * 2;
        }
    }

    public string format_timecode (int64 ns) {
        int64 v = int64.max (0, ns);
        int64 ms_total = (v + 500000) / 1000000;
        int64 ms = ms_total % 1000;
        int64 s_total = ms_total / 1000;
        int64 s = s_total % 60;
        int64 m = (s_total / 60) % 60;
        int64 h = s_total / 3600;
        return "%02d:%02d:%02d.%03d".printf ((int) h, (int) m, (int) s, (int) ms);
    }
}
