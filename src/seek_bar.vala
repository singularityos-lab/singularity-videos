namespace Singularity.Apps.Videos {

    /**
     * Scrubber for the playback position.
     *
     * Draws the played range in the accent colour over the buffered range,
     * and previews the time under the pointer in a small bubble above it.
     */
    public class SeekBar : Gtk.Widget {

        private const int TRACK = 4;
        private const int TRACK_HOVER = 6;
        private const int KNOB = 14;

        /** Played fraction, from 0 to 1. */
        public double fraction { get; set; default = 0; }

        /** Buffered fraction, from 0 to 1, or negative when unknown. */
        public double buffered { get; set; default = -1; }

        /** Stream duration in nanoseconds, used for the time preview. */
        public int64 duration { get; set; default = 0; }

        /** True while the pointer drags the knob. */
        public bool dragging { get; private set; default = false; }

        /**
         * Emitted while scrubbing and once more when the drag ends.
         *
         * @param fraction Target position, from 0 to 1.
         * @param final    False while the pointer is still moving.
         */
        public signal void seek (double fraction, bool final);

        private bool _hover = false;
        private double _hover_x = 0;
        private Gdk.RGBA _accent = Gdk.RGBA ();

        static construct {
            set_css_name ("videos-seek-bar");
            set_accessible_role (Gtk.AccessibleRole.SLIDER);
        }

        construct {
            hexpand = true;
            valign = Gtk.Align.CENTER;
            height_request = 20;
            focusable = false;
            cursor = new Gdk.Cursor.from_name ("pointer", null);
            update_property (Gtk.AccessibleProperty.LABEL, _("Position"),
                             Gtk.AccessibleProperty.VALUE_MIN, 0.0,
                             Gtk.AccessibleProperty.VALUE_MAX, 100.0, -1);

            var motion = new Gtk.EventControllerMotion ();
            motion.enter.connect ((x, y) => { _hover = true; _hover_x = x; queue_draw (); });
            motion.motion.connect ((x, y) => { _hover_x = x; queue_draw (); });
            motion.leave.connect (() => { _hover = false; queue_draw (); });
            add_controller (motion);

            var drag = new Gtk.GestureDrag ();
            drag.drag_begin.connect ((x, y) => {
                dragging = true;
                _hover_x = x;
                fraction = _fraction_at (x);
                seek (fraction, false);
            });
            drag.drag_update.connect ((dx, dy) => {
                double sx, sy;
                drag.get_start_point (out sx, out sy);
                _hover_x = sx + dx;
                fraction = _fraction_at (_hover_x);
                seek (fraction, false);
            });
            drag.drag_end.connect ((dx, dy) => {
                double sx, sy;
                drag.get_start_point (out sx, out sy);
                fraction = _fraction_at (sx + dx);
                dragging = false;
                seek (fraction, true);
            });
            add_controller (drag);

            var style = Singularity.Style.StyleManager.get_default ();
            _accent.parse (style.accent_hex);
            style.notify["accent-hex"].connect (() => {
                _accent.parse (style.accent_hex);
                queue_draw ();
            });
            notify["fraction"].connect (() => {
                update_property (Gtk.AccessibleProperty.VALUE_NOW, fraction * 100.0, -1);
                queue_draw ();
            });
            notify["buffered"].connect (queue_draw);
        }

        /** Formats a duration in nanoseconds as m:ss or h:mm:ss. */
        public static string format_time (int64 ns) {
            int total = (int) int64.max (0, ns / 1000000000);
            int h = total / 3600;
            int m = (total / 60) % 60;
            int s = total % 60;
            if (h > 0) return "%d:%02d:%02d".printf (h, m, s);
            return "%d:%02d".printf (m, s);
        }

        private double _inset () {
            return KNOB / 2.0;
        }

        private double _fraction_at (double x) {
            double span = get_width () - 2 * _inset ();
            if (span <= 0) return 0;
            return ((x - _inset ()) / span).clamp (0.0, 1.0);
        }

        public override void snapshot (Gtk.Snapshot snap) {
            int w = get_width ();
            int h = get_height ();
            double inset = _inset ();
            float span = (float) (w - 2 * inset);
            if (span <= 0) return;
            bool active = _hover || dragging;
            float th = active ? TRACK_HOVER : TRACK;
            float y = (h - th) / 2.0f;
            float r = th / 2.0f;
            float x0 = (float) inset;

            var white = Gdk.RGBA ();
            white.parse ("white");

            _bar (snap, x0, y, span, th, r, _with_alpha (white, 0.22f));
            if (buffered > 0)
                _bar (snap, x0, y, (float) (span * buffered.clamp (0, 1)), th, r, _with_alpha (white, 0.34f));
            if (active && !dragging) {
                float hx = (float) (_fraction_at (_hover_x) * span);
                _bar (snap, x0, y, hx, th, r, _with_alpha (white, 0.30f));
            }
            float px = (float) (span * fraction.clamp (0, 1));
            if (px > 0) _bar (snap, x0, y, px, th, r, _accent);

            float knob = active ? KNOB : 10;
            var knob_rect = Graphene.Rect ().init (x0 + px - knob / 2, h / 2.0f - knob / 2, knob, knob);
            var rounded = Gsk.RoundedRect ().init_from_rect (knob_rect, knob / 2);
            var shadow = Gdk.RGBA ();
            shadow.parse ("rgba(0,0,0,0.45)");
            snap.append_outset_shadow (rounded, shadow, 0, 1, 0, 3);
            snap.push_rounded_clip (rounded);
            snap.append_color (white, knob_rect);
            snap.pop ();

            if (active && duration > 0) _preview (snap, w, h, white);
        }

        private void _preview (Gtk.Snapshot snap, int w, int h, Gdk.RGBA white) {
            double f = dragging ? fraction : _fraction_at (_hover_x);
            var layout = create_pango_layout (format_time ((int64) (f * duration)));
            var attrs = new Pango.AttrList ();
            attrs.insert (Pango.attr_weight_new (Pango.Weight.SEMIBOLD));
            attrs.insert (Pango.AttrFontFeatures.new ("tnum"));
            layout.set_attributes (attrs);
            int tw, th;
            layout.get_pixel_size (out tw, out th);
            float bw = tw + 16;
            float bh = th + 6;
            float cx = (float) (_inset () + f * (w - 2 * _inset ()));
            float bx = (cx - bw / 2).clamp (-(float) _inset (), (float) (w + _inset () - bw));
            float by = -bh - 12;
            var rect = Graphene.Rect ().init (bx, by, bw, bh);
            var rounded = Gsk.RoundedRect ().init_from_rect (rect, bh / 2);
            var shadow = Gdk.RGBA ();
            shadow.parse ("rgba(0,0,0,0.4)");
            snap.append_outset_shadow (rounded, shadow, 0, 2, 0, 8);
            var fill = Gdk.RGBA ();
            fill.parse ("rgba(0,0,0,0.78)");
            var edge = _with_alpha (white, 0.16f);
            snap.push_rounded_clip (rounded);
            snap.append_color (fill, rect);
            snap.pop ();
            snap.append_border (rounded, { 1, 1, 1, 1 }, { edge, edge, edge, edge });
            snap.save ();
            snap.translate (Graphene.Point () { x = bx + 8, y = by + 3 });
            snap.append_layout (layout, white);
            snap.restore ();
        }

        private static Gdk.RGBA _with_alpha (Gdk.RGBA c, float a) {
            var out_c = c;
            out_c.alpha = a;
            return out_c;
        }

        private static void _bar (Gtk.Snapshot snap, float x, float y, float width, float height,
                                  float radius, Gdk.RGBA color) {
            if (width <= 0) return;
            var rect = Graphene.Rect ().init (x, y, width, height);
            var rounded = Gsk.RoundedRect ().init_from_rect (rect, radius);
            snap.push_rounded_clip (rounded);
            snap.append_color (color, rect);
            snap.pop ();
        }
    }
}
