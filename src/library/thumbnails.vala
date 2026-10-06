namespace Singularity.Apps.Videos {

    public class Thumbnails : GLib.Object {
        public delegate void Ready (Gdk.Texture texture);

        private static Thumbnails? _default = null;
        private Gee.HashMap<string, Gdk.Texture> _memory = new Gee.HashMap<string, Gdk.Texture> ();
        private Gee.ArrayQueue<string> _frame_queue = new Gee.ArrayQueue<string> ();
        private Gee.HashMap<string, Gee.ArrayList<ReadyBox>> _waiting = new Gee.HashMap<string, Gee.ArrayList<ReadyBox>> ();
        private bool _frame_busy = false;
        private Soup.Session _session;
        private string _dir;

        private class ReadyBox {
            public Ready cb;
            public ReadyBox (owned Ready cb) {
                this.cb = (owned) cb;
            }
        }

        public static Thumbnails get_default () {
            if (_default == null) _default = new Thumbnails ();
            return _default;
        }

        construct {
            _session = new Soup.Session ();
            _session.user_agent = "Singularity-Videos/0.1";
            _session.timeout = 20;
            _dir = GLib.Path.build_filename (GLib.Environment.get_user_cache_dir (), "dev.sinty.videos", "thumbnails");
            GLib.DirUtils.create_with_parents (_dir, 0700);
        }

        public Gdk.Texture? cached (string key) {
            return _memory[key];
        }

        private string _disk (string key) {
            return GLib.Path.build_filename (_dir, GLib.Checksum.compute_for_string (GLib.ChecksumType.MD5, key) + ".png");
        }

        private bool _from_disk (string key, Ready cb) {
            string path = _disk (key);
            if (!GLib.FileUtils.test (path, GLib.FileTest.EXISTS)) return false;
            try {
                var tex = Gdk.Texture.from_filename (path);
                _memory[key] = tex;
                cb (tex);
                return true;
            } catch (GLib.Error e) {
                return false;
            }
        }

        private void _deliver (string key, Gdk.Texture? tex) {
            var list = _waiting[key];
            _waiting.unset (key);
            if (tex == null || list == null) return;
            _memory[key] = tex;
            foreach (var b in list) b.cb (tex);
        }

        private bool _wait (string key, owned Ready cb) {
            var hit = _memory[key];
            if (hit != null) {
                cb (hit);
                return true;
            }
            var list = _waiting[key];
            if (list != null) {
                list.add (new ReadyBox ((owned) cb));
                return true;
            }
            list = new Gee.ArrayList<ReadyBox> ();
            list.add (new ReadyBox ((owned) cb));
            _waiting[key] = list;
            return false;
        }

        public void load_url (string url, owned Ready cb) {
            if (url == "") return;
            if (_wait (url, (owned) cb)) return;
            if (_from_disk (url, (t) => _deliver (url, t))) return;
            var msg = new Soup.Message ("GET", url);
            if (msg == null) {
                _deliver (url, null);
                return;
            }
            _session.send_and_read_async.begin (msg, GLib.Priority.LOW, null, (o, r) => {
                Gdk.Texture? tex = null;
                try {
                    var bytes = _session.send_and_read_async.end (r);
                    if (msg.status_code == 200 && bytes.get_size () > 0) {
                        tex = Gdk.Texture.from_bytes (bytes);
                        try {
                            GLib.FileUtils.set_data (_disk (url), bytes.get_data ());
                        } catch (GLib.Error e) {
                        }
                    }
                } catch (GLib.Error e) {
                }
                _deliver (url, tex);
            });
        }

        public void load_video_frame (string file_path, string stamp, owned Ready cb) {
            string key = "frame:" + file_path + ":" + stamp;
            if (_wait (key, (owned) cb)) return;
            if (_from_disk (key, (t) => _deliver (key, t))) return;
            _frame_queue.offer (key);
            _pump ();
        }

        private void _pump () {
            if (_frame_busy || _frame_queue.is_empty) return;
            _frame_busy = true;
            string key = _frame_queue.poll ();
            string path = key.substring (6, key.last_index_of_char (':') - 6);
            string disk = _disk (key);
            new GLib.Thread<bool> ("videos-poster", () => {
                var png = _grab (GLib.File.new_for_path (path).get_uri (), disk);
                GLib.Idle.add (() => {
                    Gdk.Texture? tex = null;
                    if (png) {
                        try {
                            tex = Gdk.Texture.from_filename (disk);
                        } catch (GLib.Error e) {
                        }
                    }
                    _deliver (key, tex);
                    _frame_busy = false;
                    _pump ();
                    return GLib.Source.REMOVE;
                });
                return true;
            });
        }

        private static bool _grab (string uri, string out_path) {
            Gst.Element pipeline;
            try {
                pipeline = Gst.parse_launch ("uridecodebin name=src expose-all-streams=false ! videoconvert ! videoscale "
                    + "! video/x-raw,format=RGBA,height=270,pixel-aspect-ratio=1/1 ! appsink name=sink sync=false max-buffers=1");
            } catch (GLib.Error e) {
                return false;
            }
            var bin = (Gst.Bin) pipeline;
            var src = bin.get_by_name ("src");
            src.set ("uri", uri);
            src.set ("caps", Gst.Caps.from_string ("video/x-raw(ANY)"));
            var sink = (Gst.App.Sink) bin.get_by_name ("sink");
            pipeline.set_state (Gst.State.PAUSED);
            Gst.State state, pending;
            if (pipeline.get_state (out state, out pending, 15 * Gst.SECOND) == Gst.StateChangeReturn.FAILURE) {
                pipeline.set_state (Gst.State.NULL);
                return false;
            }
            int64 dur = 0;
            if (pipeline.query_duration (Gst.Format.TIME, out dur) && dur > 0) {
                pipeline.seek_simple (Gst.Format.TIME, Gst.SeekFlags.FLUSH | Gst.SeekFlags.KEY_UNIT, dur / 10);
                pipeline.get_state (out state, out pending, 10 * Gst.SECOND);
            }
            var sample = sink.try_pull_preroll (5 * Gst.SECOND);
            bool ok = false;
            if (sample != null) {
                unowned Gst.Caps? caps = sample.get_caps ();
                unowned Gst.Buffer? buffer = sample.get_buffer ();
                var info = new Gst.Video.Info ();
                if (caps != null && buffer != null && info.from_caps (caps)) {
                    Gst.MapInfo map;
                    if (buffer.map (out map, Gst.MapFlags.READ)) {
                        var bytes = new GLib.Bytes (map.data[0:info.stride[0] * info.height]);
                        buffer.unmap (map);
                        var tex = new Gdk.MemoryTexture (info.width, info.height, Gdk.MemoryFormat.R8G8B8A8, bytes, info.stride[0]);
                        ok = tex.save_to_png (out_path);
                    }
                }
            }
            pipeline.set_state (Gst.State.NULL);
            return ok;
        }
    }
}
