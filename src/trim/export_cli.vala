namespace Singularity.Apps.Videos {

    namespace ExportCli {

        public int64 parse_seconds (string text) {
            return (int64) Math.round (double.parse (text.strip ()) * NS_PER_SECOND);
        }

        public bool parse_range (string text, out int64 start, out int64 end) {
            start = 0;
            end = 0;
            var parts = text.split ("-");
            if (parts.length != 2) return false;
            start = parse_seconds (parts[0]);
            end = parse_seconds (parts[1]);
            return end > start;
        }

        public EditClip? load_clip (string spec, out string? error) {
            error = null;
            string rest = spec;
            string[] cuts = {};
            int hash = rest.index_of ("#");
            if (hash >= 0) {
                cuts = rest.substring (hash + 1).split ("#");
                rest = rest.substring (0, hash);
            }
            string? trim = null;
            int at = rest.last_index_of ("@");
            if (at >= 0) {
                trim = rest.substring (at + 1);
                rest = rest.substring (0, at);
            }
            string uri = GLib.File.new_for_commandline_arg (rest).get_uri ();
            var clip = MediaProbe.probe_sync (uri, out error);
            if (clip == null) return null;
            if (trim != null) {
                int64 a, b;
                if (!parse_range (trim, out a, out b)) {
                    error = "invalid trim range %s".printf (trim);
                    return null;
                }
                clip.set_trim (a, b);
            }
            foreach (var c in cuts) {
                int64 a, b;
                if (!parse_range (c, out a, out b)) {
                    error = "invalid cut range %s".printf (c);
                    return null;
                }
                clip.add_cut (a, b);
            }
            return clip;
        }

        public int run (string[] args) {
            string? output = null;
            string format_name = "mp4";
            string quality_name = "medium";
            string? backend = null;
            int rotation = 0;
            string? crop_text = null;
            string? aspect_text = null;
            string[] specs = {};
            for (int i = 1; i < args.length; i++) {
                string a = args[i];
                bool has_next = i + 1 < args.length;
                if (a == "--out" && has_next) output = args[++i];
                else if (a == "--format" && has_next) format_name = args[++i];
                else if (a == "--quality" && has_next) quality_name = args[++i];
                else if (a == "--backend" && has_next) backend = args[++i];
                else if (a == "--rotate" && has_next) rotation = int.parse (args[++i]) / 90;
                else if (a == "--crop" && has_next) crop_text = args[++i];
                else if (a == "--aspect" && has_next) aspect_text = args[++i];
                else if (a == "--list-backends") {
                    stdout.printf ("%s\n", string.joinv (" ", ExportBackends.available ()));
                    return 0;
                } else if (a == "--help" || a.has_prefix ("--")) {
                    stdout.printf ("usage: %s --out FILE [--format mp4|webm] [--quality high|medium|small] "
                        + "[--backend pipeline|ges] [--rotate DEG] [--crop L,T,R,B] [--aspect W:H] "
                        + "CLIP[@IN-OUT][#CUTSTART-CUTEND]...\n", args[0]);
                    return a == "--help" ? 0 : 2;
                } else specs += a;
            }
            var format = ExportFormat.parse (format_name);
            var quality = ExportQuality.parse (quality_name);
            if (output == null || specs.length == 0 || format == null || quality == null) {
                stderr.printf ("missing or invalid arguments, see --help\n");
                return 2;
            }
            if (!Encoders.available (format)) {
                stderr.printf ("encoders for %s are not available\n", format_name);
                return 77;
            }
            var edl = new EditList ();
            foreach (var spec in specs) {
                string? error;
                var clip = load_clip (spec, out error);
                if (clip == null) {
                    stderr.printf ("%s: %s\n", spec, error ?? "unreadable");
                    return 1;
                }
                edl.add (clip);
            }
            edl.set_rotation (rotation);
            if (aspect_text != null) {
                var p = aspect_text.split (":");
                if (p.length == 2) {
                    int w, h;
                    edl.source_size (out w, out h);
                    int rw, rh;
                    Geometry.rotated_size (w, h, edl.rotation, out rw, out rh);
                    edl.set_crop (CropBox.with_aspect (double.parse (p[0]) / double.parse (p[1]), rw, rh));
                }
            } else if (crop_text != null) {
                var p = crop_text.split (",");
                if (p.length == 4)
                    edl.set_crop (new CropBox (double.parse (p[0]), double.parse (p[1]),
                                               double.parse (p[2]), double.parse (p[3])));
            }
            var preset = new ExportPreset (quality);
            int ow, oh;
            edl.output_size (preset, out ow, out oh);
            var exporter = ExportBackends.create (backend);
            stdout.printf ("backend=%s segments=%d expected_duration_ms=%lld width=%d height=%d\n",
                exporter.backend_id, edl.segments ().length, edl.output_duration () / 1000000, ow, oh);
            var loop = new GLib.MainLoop ();
            int status = 1;
            double last = -1;
            exporter.progress.connect ((f) => {
                if (f - last >= 0.1 || f >= 1.0) {
                    last = f;
                    stdout.printf ("progress=%.2f\n", f);
                }
            });
            exporter.finished.connect ((ok, error) => {
                if (ok) {
                    stdout.printf ("done=%s\n", output);
                    status = 0;
                } else {
                    stderr.printf ("failed: %s\n", error ?? "cancelled");
                }
                loop.quit ();
            });
            string? cancel_after = GLib.Environment.get_variable ("VIDEOS_EXPORT_CANCEL_AFTER_MS");
            if (cancel_after != null) {
                GLib.Timeout.add ((uint) int.parse (cancel_after), () => {
                    stdout.printf ("cancelling\n");
                    exporter.cancel ();
                    return GLib.Source.REMOVE;
                });
            }
            exporter.start (edl, format, preset, output);
            loop.run ();
            return status;
        }
    }
}

int main (string[] args) {
    Intl.setlocale (LocaleCategory.ALL, "");
    unowned string[] gst_args = args;
    Gst.init (ref gst_args);
    return Singularity.Apps.Videos.ExportCli.run (args);
}
