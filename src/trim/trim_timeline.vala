namespace Singularity.Apps.Videos {

    public class TrimTimeline : Gtk.Widget {

        private const int PAD = 12;
        private const int GAP = 8;
        private const int TOP = 12;
        private const int STRIP = MediaStrip.THUMB_HEIGHT;
        private const int WAVE = 34;
        private const int SPACING = 6;
        private const int BOTTOM = 8;
        private const int HANDLE = 10;
        private const double GRAB = 12;

        private enum Drag {
            NONE,
            SCRUB,
            IN,
            OUT
        }

        public signal void scrub (int clip, int64 local, bool final);
        public signal void trim_changed (int clip);
        public signal void clip_selected (int clip);

        public int selected { get; set; default = 0; }
        public int64 mark_in { get; set; default = -1; }
        public int64 mark_out { get; set; default = -1; }

        private EditList? _edl = null;
        private Gee.HashMap<EditClip, MediaStrip> _strips = new Gee.HashMap<EditClip, MediaStrip> ();
        private int _play_clip = 0;
        private int64 _play_local = 0;
        private Drag _drag = Drag.NONE;
        private int _drag_clip = -1;
        private Gdk.RGBA _accent = Gdk.RGBA ();

        static construct {
            set_css_name ("videos-trim-timeline");
            set_accessible_role (Gtk.AccessibleRole.SLIDER);
        }

        construct {
            hexpand = true;
            height_request = TOP + STRIP + SPACING + WAVE + BOTTOM;
            focusable = true;
            update_property (Gtk.AccessibleProperty.LABEL, _("Timeline"), -1);
            var style = Singularity.Style.StyleManager.get_default ();
            _accent.parse (style.accent_hex);
            style.notify["accent-hex"].connect (() => {
                _accent.parse (style.accent_hex);
                queue_draw ();
            });
            notify["selected"].connect (queue_draw);
            notify["mark-in"].connect (queue_draw);
            notify["mark-out"].connect (queue_draw);

            var drag = new Gtk.GestureDrag ();
            drag.drag_begin.connect ((x, y) => _begin (x, y));
            drag.drag_update.connect ((dx, dy) => {
                double sx, sy;
                drag.get_start_point (out sx, out sy);
                _update (sx + dx, false);
            });
            drag.drag_end.connect ((dx, dy) => {
                double sx, sy;
                drag.get_start_point (out sx, out sy);
                _update (sx + dx, true);
                _drag = Drag.NONE;
            });
            add_controller (drag);

            var motion = new Gtk.EventControllerMotion ();
            motion.motion.connect ((x, y) => {
                int clip;
                set_cursor_from_name (_handle_at (x, out clip) != Drag.NONE ? "ew-resize" : "pointer");
            });
            add_controller (motion);
        }

        public void set_list (EditList edl) {
            _edl = edl;
            edl.changed.connect (queue_draw);
            queue_draw ();
        }

        public void attach_strip (EditClip clip, MediaStrip strip) {
            _strips[clip] = strip;
            strip.thumbnail_ready.connect (() => queue_draw ());
            strip.waveform_ready.connect (queue_draw);
        }

        public void detach_strip (EditClip clip) {
            MediaStrip strip;
            if (_strips.unset (clip, out strip)) strip.stop ();
        }

        public void set_playhead (int clip, int64 local) {
            _play_clip = clip;
            _play_local = local;
            queue_draw ();
        }

        private double _usable_width () {
            int n = _edl != null ? _edl.size : 0;
            return double.max (1, get_width () - 2 * PAD - GAP * int.max (0, n - 1));
        }

        private double _clip_x (int index) {
            double total = _edl.source_duration ();
            double x = PAD;
            for (int i = 0; i < index; i++)
                x += _edl.get_clip (i).duration / total * _usable_width () + GAP;
            return x;
        }

        private double _clip_w (int index) {
            double total = _edl.source_duration ();
            return total > 0 ? _edl.get_clip (index).duration / total * _usable_width () : 0;
        }

        private double _x_of (int index, int64 local) {
            var clip = _edl.get_clip (index);
            if (clip.duration <= 0) return _clip_x (index);
            return _clip_x (index) + (double) local / clip.duration * _clip_w (index);
        }

        private int _clip_at_x (double x) {
            if (_edl == null || _edl.size == 0) return -1;
            for (int i = 0; i < _edl.size; i++) {
                if (x < _clip_x (i) + _clip_w (i) + GAP / 2.0) return i;
            }
            return _edl.size - 1;
        }

        private int64 _local_at (int index, double x) {
            var clip = _edl.get_clip (index);
            double w = _clip_w (index);
            if (w <= 0) return 0;
            double f = ((x - _clip_x (index)) / w).clamp (0, 1);
            return clip.snap ((int64) (f * clip.duration));
        }

        private Drag _handle_at (double x, out int clip) {
            clip = -1;
            if (_edl == null) return Drag.NONE;
            for (int i = 0; i < _edl.size; i++) {
                var c = _edl.get_clip (i);
                if ((x - _x_of (i, c.in_point)).abs () <= GRAB) {
                    clip = i;
                    return Drag.IN;
                }
                if ((x - _x_of (i, c.out_point)).abs () <= GRAB) {
                    clip = i;
                    return Drag.OUT;
                }
            }
            return Drag.NONE;
        }

        private void _begin (double x, double y) {
            if (_edl == null || _edl.size == 0) return;
            grab_focus ();
            int clip;
            _drag = _handle_at (x, out clip);
            if (_drag == Drag.NONE) {
                _drag = Drag.SCRUB;
                clip = _clip_at_x (x);
            }
            _drag_clip = clip;
            if (clip != selected) {
                selected = clip;
                clip_selected (clip);
            }
            _update (x, false);
        }

        private void _update (double x, bool final) {
            if (_drag == Drag.NONE || _edl == null || _drag_clip < 0 || _drag_clip >= _edl.size) return;
            var clip = _edl.get_clip (_drag_clip);
            int64 local = _local_at (_drag_clip, x);
            int64 min_len = clip.frame_duration ();
            switch (_drag) {
                case Drag.IN:
                    local = int64.min (local, clip.out_point - min_len);
                    clip.set_trim (local, clip.out_point);
                    trim_changed (_drag_clip);
                    break;
                case Drag.OUT:
                    local = int64.max (local, clip.in_point + min_len);
                    clip.set_trim (clip.in_point, local);
                    trim_changed (_drag_clip);
                    break;
                default:
                    break;
            }
            _play_clip = _drag_clip;
            _play_local = local;
            queue_draw ();
            scrub (_drag_clip, local, final);
            if (final && _drag != Drag.SCRUB) _edl.notify_changed ();
        }

        public override void snapshot (Gtk.Snapshot snap) {
            if (_edl == null || _edl.size == 0) return;
            float strip_y = TOP;
            float wave_y = TOP + STRIP + SPACING;
            for (int i = 0; i < _edl.size; i++) _draw_clip (snap, i, strip_y, wave_y);
            if (_play_clip >= 0 && _play_clip < _edl.size) {
                float px = (float) _x_of (_play_clip, _play_local);
                var white = Gdk.RGBA ();
                white.parse ("white");
                var shadow = Gdk.RGBA ();
                shadow.parse ("rgba(0,0,0,0.5)");
                snap.append_color (shadow, Graphene.Rect ().init (px - 2, 2, 4, get_height () - 4));
                snap.append_color (white, Graphene.Rect ().init (px - 1, 2, 2, get_height () - 4));
                var knob = Graphene.Rect ().init (px - 6, 0, 12, 10);
                var rounded = Gsk.RoundedRect ().init_from_rect (knob, 3);
                snap.push_rounded_clip (rounded);
                snap.append_color (white, knob);
                snap.pop ();
            }
        }

        private void _draw_clip (Gtk.Snapshot snap, int index, float strip_y, float wave_y) {
            var clip = _edl.get_clip (index);
            float x = (float) _clip_x (index);
            float w = (float) _clip_w (index);
            if (w <= 1) return;
            var strip_rect = Graphene.Rect ().init (x, strip_y, w, STRIP);
            var wave_rect = Graphene.Rect ().init (x, wave_y, w, WAVE);
            var bg = Gdk.RGBA ();
            bg.parse ("#1d1f24");
            foreach (var r in new Graphene.Rect[] { strip_rect, wave_rect }) {
                var rounded = Gsk.RoundedRect ().init_from_rect (r, 6);
                snap.push_rounded_clip (rounded);
                snap.append_color (bg, r);
                snap.pop ();
            }

            MediaStrip? strip = _strips.has_key (clip) ? _strips[clip] : null;
            var strip_clip = Gsk.RoundedRect ().init_from_rect (strip_rect, 6);
            snap.push_rounded_clip (strip_clip);
            if (strip != null && strip.thumbnail_count > 0) {
                int n = strip.thumbnail_count;
                float cell = w / n;
                for (int i = 0; i < n; i++) {
                    var tex = strip.thumbnail (i);
                    if (tex == null) continue;
                    float tw = (float) STRIP * tex.get_width () / int.max (1, tex.get_height ());
                    float cx = x + cell * i;
                    snap.push_clip (Graphene.Rect ().init (cx, strip_y, cell + 0.5f, STRIP));
                    snap.append_texture (tex, Graphene.Rect ().init (cx + (cell - tw) / 2, strip_y, tw, STRIP));
                    snap.pop ();
                }
            } else if (!clip.has_video) {
                var tint = Gdk.RGBA ();
                tint.parse ("#2a2f3a");
                snap.append_color (tint, strip_rect);
            }
            snap.pop ();

            var wave_clip = Gsk.RoundedRect ().init_from_rect (wave_rect, 6);
            snap.push_rounded_clip (wave_clip);
            if (strip != null && strip.peaks ().length > 0) {
                var bar = Gdk.RGBA ();
                bar.parse ("#8fd3ff");
                bar.alpha = 0.85f;
                unowned float[] peaks = strip.peaks ();
                float mid = wave_y + WAVE / 2.0f;
                for (int px = 0; px < (int) w; px += 2) {
                    int a = (int) ((double) px / w * peaks.length);
                    int b = int.min (peaks.length, (int) ((double) (px + 2) / w * peaks.length) + 1);
                    float v = 0;
                    for (int k = a; k < b; k++) v = float.max (v, peaks[k]);
                    float h = float.max (1, (float) Math.sqrt (v.clamp (0, 1)) * (WAVE - 6));
                    snap.append_color (bar, Graphene.Rect ().init (x + px, mid - h / 2, 1.5f, h));
                }
            } else if (clip.has_audio) {
                var line = Gdk.RGBA ();
                line.parse ("rgba(255,255,255,0.18)");
                snap.append_color (line, Graphene.Rect ().init (x + 6, wave_y + WAVE / 2.0f, w - 12, 1));
            }
            snap.pop ();

            var shade = Gdk.RGBA ();
            shade.parse ("rgba(0,0,0,0.68)");
            float in_x = (float) _x_of (index, clip.in_point);
            float out_x = (float) _x_of (index, clip.out_point);
            foreach (var r in new Graphene.Rect[] { strip_rect, wave_rect }) {
                _band (snap, x, in_x, r, shade);
                _band (snap, out_x, x + w, r, shade);
            }

            var cut_shade = Gdk.RGBA ();
            cut_shade.parse ("rgba(20,4,6,0.72)");
            var cut_edge = Gdk.RGBA ();
            cut_edge.parse ("#ff5a67");
            foreach (var c in clip.cuts ()) {
                float cx0 = (float) _x_of (index, c.start);
                float cx1 = (float) _x_of (index, c.end);
                foreach (var r in new Graphene.Rect[] { strip_rect, wave_rect }) {
                    _band (snap, cx0, cx1, r, cut_shade);
                    _hatch (snap, cx0, cx1, r, cut_edge);
                }
                snap.append_color (cut_edge, Graphene.Rect ().init (cx0, strip_y, 2, wave_y + WAVE - strip_y));
                snap.append_color (cut_edge, Graphene.Rect ().init (cx1 - 2, strip_y, 2, wave_y + WAVE - strip_y));
            }

            if (index == selected && mark_in >= 0 && mark_out > mark_in) {
                var sel = _accent;
                sel.alpha = 0.28f;
                float sx0 = (float) _x_of (index, mark_in);
                float sx1 = (float) _x_of (index, mark_out);
                foreach (var r in new Graphene.Rect[] { strip_rect, wave_rect }) _band (snap, sx0, sx1, r, sel);
                var line = _accent;
                snap.append_color (line, Graphene.Rect ().init (sx0 - 1, strip_y - 4, 2, wave_y + WAVE - strip_y + 8));
                snap.append_color (line, Graphene.Rect ().init (sx1 - 1, strip_y - 4, 2, wave_y + WAVE - strip_y + 8));
            }

            var frame_color = index == selected ? _accent : Gdk.RGBA () { red = 1, green = 1, blue = 1, alpha = 0.55f };
            float fh = wave_y + WAVE - strip_y;
            var frame = Graphene.Rect ().init (in_x, strip_y, float.max (2, out_x - in_x), fh);
            var frame_round = Gsk.RoundedRect ().init_from_rect (frame, 6);
            float bw = index == selected ? 3 : 1.5f;
            snap.append_border (frame_round, { bw, bw, bw, bw }, { frame_color, frame_color, frame_color, frame_color });
            if (index == selected) {
                _handle (snap, in_x - HANDLE / 2.0f, strip_y, fh, frame_color);
                _handle (snap, out_x - HANDLE / 2.0f, strip_y, fh, frame_color);
            }
        }

        private static void _band (Gtk.Snapshot snap, float x0, float x1, Graphene.Rect r, Gdk.RGBA color) {
            float a = float.max (x0, r.origin.x);
            float b = float.min (x1, r.origin.x + r.size.width);
            if (b <= a) return;
            snap.append_color (color, Graphene.Rect ().init (a, r.origin.y, b - a, r.size.height));
        }

        private static void _hatch (Gtk.Snapshot snap, float x0, float x1, Graphene.Rect r, Gdk.RGBA color) {
            float a = float.max (x0, r.origin.x);
            float b = float.min (x1, r.origin.x + r.size.width);
            if (b <= a) return;
            var stripe = color;
            stripe.alpha = 0.35f;
            snap.push_clip (Graphene.Rect ().init (a, r.origin.y, b - a, r.size.height));
            for (float sx = a - r.size.height; sx < b; sx += 9) {
                for (int k = 0; k < (int) r.size.height; k += 3) {
                    snap.append_color (stripe, Graphene.Rect ().init (sx + k, r.origin.y + k, 2, 3));
                }
            }
            snap.pop ();
        }

        private static void _handle (Gtk.Snapshot snap, float x, float y, float h, Gdk.RGBA color) {
            var rect = Graphene.Rect ().init (x, y, HANDLE, h);
            var rounded = Gsk.RoundedRect ().init_from_rect (rect, 4);
            var shadow = Gdk.RGBA ();
            shadow.parse ("rgba(0,0,0,0.45)");
            snap.append_outset_shadow (rounded, shadow, 0, 1, 0, 3);
            snap.push_rounded_clip (rounded);
            snap.append_color (color, rect);
            snap.pop ();
            var grip = Gdk.RGBA ();
            grip.parse ("rgba(0,0,0,0.55)");
            snap.append_color (grip, Graphene.Rect ().init (x + HANDLE / 2.0f - 1, y + h / 2 - 8, 2, 16));
        }
    }
}
