namespace Singularity.Apps.Videos {

    public class HistoryEntry : GLib.Object {
        public string uri = "";
        public int64 position = 0;
        public int64 duration = 0;
        public int64 played = 0;
        public string source_id = "";
        public string item_id = "";
        public string stored_title = "";
        public string image_url = "";

        public bool remote {
            get { return source_id != "" && item_id != ""; }
        }

        public string title {
            owned get {
                if (stored_title != "") return stored_title;
                var file = GLib.File.new_for_uri (uri);
                string name = file.get_basename () ?? uri;
                int dot = name.last_index_of_char ('.');
                return dot > 0 ? name.substring (0, dot) : name;
            }
        }

        public bool resumable {
            get {
                return position > 10000000000 && (duration <= 0 || position < duration - 15000000000);
            }
        }
    }

    public class VideoHistory : GLib.Object {
        private const int MAX_ENTRIES = 30;
        private const int64 NS = 1000000000;

        private string path;

        public VideoHistory () {
            path = GLib.Path.build_filename (GLib.Environment.get_user_data_dir (), "singularity-videos", "history.ini");
        }

        public static bool enabled () {
            return Singularity.Runtime.file_history_enabled ();
        }

        private GLib.KeyFile load () {
            var kf = new GLib.KeyFile ();
            try {
                kf.load_from_file (path, GLib.KeyFileFlags.NONE);
            } catch (GLib.Error e) {}
            return kf;
        }

        public HistoryEntry[] entries () {
            var kf = load ();
            HistoryEntry[] list = {};
            foreach (var group in kf.get_groups ()) {
                var e = new HistoryEntry ();
                e.uri = group;
                try {
                    e.position = kf.get_int64 (group, "position");
                    e.duration = kf.get_int64 (group, "duration");
                    e.played = kf.get_int64 (group, "played");
                } catch (GLib.Error err) {}
                try {
                    e.source_id = kf.get_string (group, "source");
                    e.item_id = kf.get_string (group, "item");
                } catch (GLib.Error err) {}
                try {
                    e.stored_title = kf.get_string (group, "title");
                } catch (GLib.Error err) {}
                try {
                    e.image_url = kf.get_string (group, "image");
                } catch (GLib.Error err) {}
                list += e;
            }
            for (int i = 1; i < list.length; i++) {
                var cur = list[i];
                int j = i - 1;
                while (j >= 0 && list[j].played < cur.played) {
                    list[j + 1] = list[j];
                    j--;
                }
                list[j + 1] = cur;
            }
            return list;
        }

        public HistoryEntry[] recent (int limit) {
            HistoryEntry[] list = {};
            if (!enabled ()) return list;
            foreach (var e in entries ()) {
                if (list.length >= limit) break;
                var file = GLib.File.new_for_uri (e.uri);
                if (!e.remote && file.is_native () && !file.query_exists ()) continue;
                list += e;
            }
            return list;
        }

        public HistoryEntry? find (string uri) {
            foreach (var e in entries ()) if (e.uri == uri) return e;
            return null;
        }

        public void record (string uri, int64 position, int64 duration) {
            record_item (uri, position, duration, "", "", "", "");
        }

        public static string remote_key (string source_id, string item_id) {
            return "videos-source:" + GLib.Uri.escape_string (source_id, null, false) + "/" + GLib.Uri.escape_string (item_id, null, false);
        }

        public void record_item (string uri, int64 position, int64 duration, string title, string source_id, string item_id, string image_url) {
            if (!enabled () || uri == "") return;
            var kf = load ();
            kf.set_int64 (uri, "position", position);
            kf.set_int64 (uri, "duration", duration);
            if (source_id != "") {
                kf.set_string (uri, "source", source_id);
                kf.set_string (uri, "item", item_id);
            }
            if (title != "") kf.set_string (uri, "title", title);
            if (image_url != "") kf.set_string (uri, "image", image_url);
            kf.set_int64 (uri, "played", GLib.get_real_time () / 1000000);
            var all = kf.get_groups ();
            if (all.length > MAX_ENTRIES) {
                string? oldest = null;
                int64 oldest_time = int64.MAX;
                foreach (var g in all) {
                    int64 t = 0;
                    try { t = kf.get_int64 (g, "played"); } catch (GLib.Error e) {}
                    if (t < oldest_time) { oldest_time = t; oldest = g; }
                }
                if (oldest != null) {
                    try { kf.remove_group (oldest); } catch (GLib.Error e) {}
                }
            }
            write (kf);
        }

        public void clear () {
            write (new GLib.KeyFile ());
        }

        private void write (GLib.KeyFile kf) {
            try {
                GLib.DirUtils.create_with_parents (GLib.Path.get_dirname (path), 0700);
                kf.save_to_file (path);
            } catch (GLib.Error e) {
                warning ("videos history: %s", e.message);
            }
        }

        public static string format_time (int64 ns) {
            int64 total = ns / NS;
            int64 h = total / 3600;
            int64 m = (total % 3600) / 60;
            int64 s = total % 60;
            if (h > 0) return "%d:%02d:%02d".printf ((int) h, (int) m, (int) s);
            return "%d:%02d".printf ((int) m, (int) s);
        }

        public static string label_for (HistoryEntry e) {
            if (e.resumable) return _("%s, at %s").printf (e.title, format_time (e.position));
            return e.title;
        }
    }
}
