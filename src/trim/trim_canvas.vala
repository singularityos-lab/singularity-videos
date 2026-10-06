namespace Singularity.Apps.Videos {

    public class TrimCanvas : Gtk.Widget {

        private const double HANDLE = 16;
        private const double EDGE = 10;
        private const int PAD = 16;

        private enum Grab {
            NONE,
            MOVE,
            TOP_LEFT,
            TOP_RIGHT,
            BOTTOM_LEFT,
            BOTTOM_RIGHT,
            LEFT,
            RIGHT,
            TOP,
            BOTTOM
        }

        public signal void crop_changed (CropBox box, bool final);

        public int rotation { get; set; default = 0; }
        public bool crop_mode { get; set; default = false; }
        public double aspect { get; set; default = 0; }
        public double overlay_opacity { get; set; default = 0; }

        public CropBox crop {
            get { return _crop; }
            set {
                _crop = value;
                queue_draw ();
            }
        }

        private Gdk.Paintable? _paintable = null;
        private CropBox _crop = new CropBox ();
        private Grab _grab = Grab.NONE;
        private CropBox _grab_start = new CropBox ();
        private Gdk.RGBA _accent = Gdk.RGBA ();

        static construct {
            set_css_name ("videos-trim-canvas");
        }

        construct {
            hexpand = true;
            vexpand = true;
            overflow = Gtk.Overflow.HIDDEN;
            var style = Singularity.Style.StyleManager.get_default ();
            _accent.parse (style.accent_hex);
            style.notify["accent-hex"].connect (() => {
                _accent.parse (style.accent_hex);
                queue_draw ();
            });
            notify["rotation"].connect (queue_draw);
            notify["overlay-opacity"].connect (queue_draw);
            notify["crop-mode"].connect (() => {
                Singularity.Motion.tween (this, "overlay-opacity", crop_mode ? 1.0 : 0.0,
                    Singularity.Motion.Duration.MEDIUM,
                    crop_mode ? Singularity.Motion.Curve.ENTER : Singularity.Motion.Curve.EXIT);
                _update_cursor (-1, -1);
            });

            var drag = new Gtk.GestureDrag ();
            drag.drag_begin.connect ((x, y) => {
                _grab = crop_mode ? _hit (x, y) : Grab.NONE;
                _grab_start = _crop;
                if (_grab == Grab.NONE) drag.set_state (Gtk.EventSequenceState.DENIED);
            });
            drag.drag_update.connect ((dx, dy) => _drag_to (dx, dy, false));
            drag.drag_end.connect ((dx, dy) => {
                if (_grab != Grab.NONE) _drag_to (dx, dy, true);
                _grab = Grab.NONE;
            });
            add_controller (drag);

            var motion = new Gtk.EventControllerMotion ();
            motion.motion.connect ((x, y) => _update_cursor (x, y));
            add_controller (motion);
        }

        public void set_paintable (Gdk.Paintable? paintable) {
            _paintable = paintable;
            if (paintable != null) {
                paintable.invalidate_contents.connect (queue_draw);
                paintable.invalidate_size.connect (queue_draw);
            }
            queue_draw ();
        }

        public void frame_size (out int width, out int height) {
            width = 16;
            height = 9;
            if (_paintable != null && _paintable.get_intrinsic_width () > 0 && _paintable.get_intrinsic_height () > 0) {
                width = _paintable.get_intrinsic_width ();
                height = _paintable.get_intrinsic_height ();
                double ratio = _paintable.get_intrinsic_aspect_ratio ();
                if (ratio > 0) width = (int) Math.round (height * ratio);
            }
        }

        private Graphene.Rect _frame_rect () {
            int fw, fh;
            frame_size (out fw, out fh);
            int rw, rh;
            Geometry.rotated_size (fw, fh, rotation, out rw, out rh);
            int top = Singularity.Widgets.titlebar_inset_for (this) > 0 ? Singularity.Widgets.VIEW_EDGE_INSET_HEIGHT : PAD;
            double avail_w = double.max (1, get_width () - 2 * PAD);
            double avail_h = double.max (1, get_height () - top - PAD);
            double scale = double.min (avail_w / rw, avail_h / rh);
            float w = (float) (rw * scale);
            float h = (float) (rh * scale);
            return Graphene.Rect ().init ((get_width () - w) / 2.0f, top + ((float) avail_h - h) / 2.0f, w, h);
        }

        private Graphene.Rect _crop_rect (Graphene.Rect f, CropBox box) {
            return Graphene.Rect ().init (
                (float) (f.origin.x + box.left * f.size.width),
                (float) (f.origin.y + box.top * f.size.height),
                (float) (f.size.width * box.width_fraction ()),
                (float) (f.size.height * box.height_fraction ()));
        }

        public override void snapshot (Gtk.Snapshot snap) {
            var f = _frame_rect ();
            if (_paintable != null) {
                snap.save ();
                snap.translate (Graphene.Point () { x = f.origin.x + f.size.width / 2, y = f.origin.y + f.size.height / 2 });
                snap.rotate (90.0f * (((rotation % 4) + 4) % 4));
                bool odd = rotation % 2 != 0;
                float dw = odd ? f.size.height : f.size.width;
                float dh = odd ? f.size.width : f.size.height;
                snap.translate (Graphene.Point () { x = -dw / 2, y = -dh / 2 });
                _paintable.snapshot (snap, dw, dh);
                snap.restore ();
            }
            var c = _crop_rect (f, _crop);
            float shade = (float) (0.55 + 0.25 * (1.0 - overlay_opacity));
            if (!_crop.is_identity () || overlay_opacity > 0.01) {
                var dim = Gdk.RGBA ();
                dim.parse ("black");
                dim.alpha = _crop.is_identity () ? 0 : shade;
                _fill (snap, f.origin.x, f.origin.y, f.size.width, c.origin.y - f.origin.y, dim);
                _fill (snap, f.origin.x, c.origin.y + c.size.height, f.size.width,
                       f.origin.y + f.size.height - c.origin.y - c.size.height, dim);
                _fill (snap, f.origin.x, c.origin.y, c.origin.x - f.origin.x, c.size.height, dim);
                _fill (snap, c.origin.x + c.size.width, c.origin.y,
                       f.origin.x + f.size.width - c.origin.x - c.size.width, c.size.height, dim);
            }
            if (overlay_opacity <= 0.01) return;
            float a = (float) overlay_opacity;
            var white = Gdk.RGBA ();
            white.parse ("white");
            white.alpha = 0.35f * a;
            for (int i = 1; i < 3; i++) {
                _fill (snap, c.origin.x + c.size.width * i / 3.0f, c.origin.y, 1, c.size.height, white);
                _fill (snap, c.origin.x, c.origin.y + c.size.height * i / 3.0f, c.size.width, 1, white);
            }
            var edge = Gdk.RGBA ();
            edge.parse ("white");
            edge.alpha = 0.9f * a;
            var border = Gsk.RoundedRect ().init_from_rect (c, 0);
            snap.append_border (border, { 2, 2, 2, 2 }, { edge, edge, edge, edge });
            var knob = _accent;
            knob.alpha = a;
            float L = 22, T = 5;
            float x0 = c.origin.x, y0 = c.origin.y, x1 = c.origin.x + c.size.width, y1 = c.origin.y + c.size.height;
            _fill (snap, x0 - T / 2, y0 - T / 2, L, T, knob);
            _fill (snap, x0 - T / 2, y0 - T / 2, T, L, knob);
            _fill (snap, x1 - L + T / 2, y0 - T / 2, L, T, knob);
            _fill (snap, x1 - T / 2, y0 - T / 2, T, L, knob);
            _fill (snap, x0 - T / 2, y1 - T / 2, L, T, knob);
            _fill (snap, x0 - T / 2, y1 - L + T / 2, T, L, knob);
            _fill (snap, x1 - L + T / 2, y1 - T / 2, L, T, knob);
            _fill (snap, x1 - T / 2, y1 - L + T / 2, T, L, knob);
        }

        private static void _fill (Gtk.Snapshot snap, float x, float y, float w, float h, Gdk.RGBA color) {
            if (w <= 0 || h <= 0 || color.alpha <= 0) return;
            snap.append_color (color, Graphene.Rect ().init (x, y, w, h));
        }

        private Grab _hit (double x, double y) {
            var c = _crop_rect (_frame_rect (), _crop);
            double x0 = c.origin.x, y0 = c.origin.y, x1 = x0 + c.size.width, y1 = y0 + c.size.height;
            bool near_l = (x - x0).abs () <= HANDLE, near_r = (x - x1).abs () <= HANDLE;
            bool near_t = (y - y0).abs () <= HANDLE, near_b = (y - y1).abs () <= HANDLE;
            if (near_l && near_t) return Grab.TOP_LEFT;
            if (near_r && near_t) return Grab.TOP_RIGHT;
            if (near_l && near_b) return Grab.BOTTOM_LEFT;
            if (near_r && near_b) return Grab.BOTTOM_RIGHT;
            bool inside_y = y > y0 && y < y1, inside_x = x > x0 && x < x1;
            if (aspect <= 0) {
                if ((x - x0).abs () <= EDGE && inside_y) return Grab.LEFT;
                if ((x - x1).abs () <= EDGE && inside_y) return Grab.RIGHT;
                if ((y - y0).abs () <= EDGE && inside_x) return Grab.TOP;
                if ((y - y1).abs () <= EDGE && inside_x) return Grab.BOTTOM;
            }
            if (inside_x && inside_y) return Grab.MOVE;
            return Grab.NONE;
        }

        private void _update_cursor (double x, double y) {
            string? name = null;
            if (crop_mode && x >= 0) {
                switch (_hit (x, y)) {
                    case Grab.MOVE: name = "move"; break;
                    case Grab.TOP_LEFT: name = "nw-resize"; break;
                    case Grab.TOP_RIGHT: name = "ne-resize"; break;
                    case Grab.BOTTOM_LEFT: name = "sw-resize"; break;
                    case Grab.BOTTOM_RIGHT: name = "se-resize"; break;
                    case Grab.LEFT:
                    case Grab.RIGHT: name = "ew-resize"; break;
                    case Grab.TOP:
                    case Grab.BOTTOM: name = "ns-resize"; break;
                    default: break;
                }
            }
            set_cursor_from_name (name);
        }

        private void _drag_to (double dx, double dy, bool final) {
            if (_grab == Grab.NONE) return;
            var f = _frame_rect ();
            if (f.size.width <= 0 || f.size.height <= 0) return;
            double fx = dx / f.size.width;
            double fy = dy / f.size.height;
            var s = _grab_start;
            double l = s.left, t = s.top, r = s.right, b = s.bottom;
            double min = CropBox.MIN_SIZE;
            switch (_grab) {
                case Grab.MOVE:
                    double mx = fx.clamp (-l, r);
                    double my = fy.clamp (-t, b);
                    l += mx;
                    r -= mx;
                    t += my;
                    b -= my;
                    break;
                case Grab.LEFT:
                    l = (l + fx).clamp (0, 1 - r - min);
                    break;
                case Grab.RIGHT:
                    r = (r - fx).clamp (0, 1 - l - min);
                    break;
                case Grab.TOP:
                    t = (t + fy).clamp (0, 1 - b - min);
                    break;
                case Grab.BOTTOM:
                    b = (b - fy).clamp (0, 1 - t - min);
                    break;
                default:
                    bool left = _grab == Grab.TOP_LEFT || _grab == Grab.BOTTOM_LEFT;
                    bool top = _grab == Grab.TOP_LEFT || _grab == Grab.TOP_RIGHT;
                    if (left) l = (l + fx).clamp (0, 1 - r - min);
                    else r = (r - fx).clamp (0, 1 - l - min);
                    if (aspect > 0) {
                        double w_px = (1 - l - r) * f.size.width;
                        double h_frac = w_px / aspect / f.size.height;
                        double limit = top ? 1 - b : 1 - t;
                        if (h_frac > limit) {
                            h_frac = limit;
                            double w_frac = h_frac * f.size.height * aspect / f.size.width;
                            if (left) l = 1 - r - w_frac;
                            else r = 1 - l - w_frac;
                        }
                        if (top) t = 1 - b - h_frac;
                        else b = 1 - t - h_frac;
                    } else {
                        if (top) t = (t + fy).clamp (0, 1 - b - min);
                        else b = (b - fy).clamp (0, 1 - t - min);
                    }
                    break;
            }
            _crop = new CropBox (l, t, r, b).normalized ();
            queue_draw ();
            crop_changed (_crop, final);
        }
    }
}
