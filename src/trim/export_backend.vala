namespace Singularity.Apps.Videos {

    public abstract class ExportBackend : GLib.Object {

        public signal void progress (double fraction);
        public signal void finished (bool success, string? error);

        public abstract string backend_id { get; }

        public bool running { get; protected set; default = false; }
        public string output_path { get; protected set; default = ""; }

        protected double position_fraction = 0;
        private uint _tick_id = 0;
        private bool _done = false;

        public abstract void start (EditList edl, ExportFormat format, ExportPreset preset, string output_path);

        public abstract void cancel ();

        protected void begin_run (string path) {
            output_path = path;
            running = true;
            _done = false;
            position_fraction = 0;
            _tick_id = GLib.Timeout.add (100, () => {
                progress (position_fraction.clamp (0, 1));
                return GLib.Source.CONTINUE;
            });
        }

        protected void finish_run (bool success, string? error) {
            GLib.Idle.add (() => {
                if (_done) return GLib.Source.REMOVE;
                _done = true;
                if (_tick_id != 0) {
                    GLib.Source.remove (_tick_id);
                    _tick_id = 0;
                }
                running = false;
                if (!success) _discard_output ();
                else progress (1.0);
                finished (success, error);
                return GLib.Source.REMOVE;
            });
        }

        private void _discard_output () {
            if (output_path == "") return;
            GLib.FileUtils.unlink (output_path);
        }
    }

    namespace ExportBackends {

        public bool ges_compiled () {
#if HAVE_GES
            return true;
#else
            return false;
#endif
        }

        public string[] available () {
            string[] ids = { "pipeline" };
#if HAVE_GES
            if (GesExporter.usable ()) ids += "ges";
#endif
            return ids;
        }

        public ExportBackend create (string? prefer = null) {
            string choice = prefer ?? ExportConfig.get_default ().backend ();
#if HAVE_GES
            if ((choice == "ges" || choice == "auto") && GesExporter.usable ()) return new GesExporter ();
#endif
            if (choice == "ges") warning ("videos: the GES export backend is not available, using the pipeline backend");
            return new PipelineExporter ();
        }
    }
}
