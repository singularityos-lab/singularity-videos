namespace Singularity.Apps.Videos {

    public class PosterFrame : Gtk.Widget {
        public const int WIDTH = 224;
        public const int HEIGHT = 126;

        private Gdk.Paintable? _paintable = null;

        static construct {
            set_css_name ("videos-poster-frame");
        }

        construct {
            overflow = Gtk.Overflow.HIDDEN;
            add_css_class ("videos-poster");
        }

        public Gdk.Paintable? paintable {
            get { return _paintable; }
            set {
                _paintable = value;
                queue_draw ();
            }
        }

        public override Gtk.SizeRequestMode get_request_mode () {
            return Gtk.SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure (Gtk.Orientation orientation, int for_size, out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
            minimum = natural = orientation == Gtk.Orientation.HORIZONTAL ? WIDTH : HEIGHT;
            minimum_baseline = natural_baseline = -1;
        }

        public override void snapshot (Gtk.Snapshot snap) {
            if (_paintable == null) {
                base.snapshot (snap);
                return;
            }
            double w = get_width ();
            double h = get_height ();
            double pw = _paintable.get_intrinsic_width ();
            double ph = _paintable.get_intrinsic_height ();
            if (pw <= 0 || ph <= 0) {
                pw = w;
                ph = h;
            }
            double scale = double.max (w / pw, h / ph);
            double dw = pw * scale;
            double dh = ph * scale;
            snap.push_clip (Graphene.Rect ().init (0, 0, (float) w, (float) h));
            snap.save ();
            snap.translate (Graphene.Point () { x = (float) ((w - dw) / 2), y = (float) ((h - dh) / 2) });
            _paintable.snapshot (snap, dw, dh);
            snap.restore ();
            snap.pop ();
            base.snapshot (snap);
        }
    }
}
