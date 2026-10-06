using Singularity.MediaSources;

namespace Singularity.Apps.Videos {

    public class LocalVideosSource : GLib.Object, MediaSource, Browsable, Searchable, PlaybackResolver {
        public const string ID = "local";
        private const string[] VIDEO_EXT = { ".mp4", ".m4v", ".mkv", ".webm", ".mov", ".avi", ".ogv", ".mpg", ".mpeg", ".ts", ".wmv", ".flv" };

        private MediaHost? _host = null;
        public string? root_override = null;

        public string id { owned get { return ID; } }
        public string title { owned get { return _("Videos"); } }
        public string icon_name { owned get { return "folder-videos-symbolic"; } }
        public MediaKind kinds { get { return MediaKind.VIDEO; } }
        public SourceFeatures features { get { return SourceFeatures.BROWSE | SourceFeatures.SEARCH | SourceFeatures.PLAY; } }
        public string? account_capability { owned get { return null; } }

        public void activate (MediaHost host) {
            _host = host;
        }

        public void deactivate () {
            _host = null;
        }

        public string root_path () {
            if (root_override != null) return root_override;
            string? dir = GLib.Environment.get_user_special_dir (GLib.UserDirectory.VIDEOS);
            if (dir == null || dir == "" || dir == GLib.Environment.get_home_dir ()) dir = GLib.Path.build_filename (GLib.Environment.get_home_dir (), "Videos");
            return dir;
        }

        public static bool is_video (string name, string? ctype) {
            if (ctype != null && ctype.has_prefix ("video/")) return true;
            string n = name.down ();
            foreach (string e in VIDEO_EXT) if (n.has_suffix (e)) return true;
            return false;
        }

        private static string title_of (string name) {
            int dot = name.last_index_of_char ('.');
            return dot > 0 ? name.substring (0, dot) : name;
        }

        private async Gee.List<MediaItem> list (string path, GLib.Cancellable? c) throws GLib.Error {
            var dir = GLib.File.new_for_path (path);
            var folders = new Gee.ArrayList<MediaItem> ();
            var files = new Gee.ArrayList<MediaItem> ();
            GLib.FileEnumerator e;
            try {
                e = yield dir.enumerate_children_async ("standard::name,standard::type,standard::content-type,standard::is-hidden,time::modified",
                    GLib.FileQueryInfoFlags.NONE, GLib.Priority.DEFAULT, c);
            } catch (GLib.IOError.NOT_FOUND err) {
                return files;
            }
            while (true) {
                var infos = yield e.next_files_async (100, GLib.Priority.DEFAULT, c);
                if (infos == null) break;
                foreach (var info in infos) {
                    if (info.get_is_hidden ()) continue;
                    string name = info.get_name ();
                    string child = GLib.Path.build_filename (path, name);
                    if (info.get_file_type () == GLib.FileType.DIRECTORY) {
                        var it = new MediaItem (ID, "dir:" + child, ItemKind.FOLDER, name);
                        folders.add (it);
                        continue;
                    }
                    if (!is_video (name, info.get_content_type ())) continue;
                    var it = new MediaItem (ID, "file:" + child, ItemKind.VIDEO, title_of (name));
                    var mod = info.get_modification_date_time ();
                    if (mod != null) {
                        it.year = mod.get_year ();
                        it.set_extra ("modified", mod.to_unix ().to_string ());
                    }
                    it.stream_uri = GLib.File.new_for_path (child).get_uri ();
                    it.set_extra ("thumbnail-file", child);
                    files.add (it);
                }
            }
            folders.sort ((a, b) => GLib.strcmp (a.title.collate_key (), b.title.collate_key ()));
            files.sort ((a, b) => GLib.strcmp (a.title.collate_key_for_filename (), b.title.collate_key_for_filename ()));
            var all = new Gee.ArrayList<MediaItem> ();
            all.add_all (folders);
            all.add_all (files);
            return all;
        }

        public async MediaPage browse (string? node, string? token, GLib.Cancellable? c) throws GLib.Error {
            string path = node == null || node == "" ? root_path () : node.substring (4);
            var page = new MediaPage (node == null || node == "" ? title : GLib.Path.get_basename (path));
            foreach (var it in yield list (path, c)) page.add (it);
            page.total = page.items.size;
            if (page.items.size == 0 && (node == null || node == "")) page.notice = _("Videos you save in your Videos folder appear here.");
            return page;
        }

        public async MediaPage search (string query, MediaKind kinds, string? token, GLib.Cancellable? c) throws GLib.Error {
            var page = new MediaPage (_("Results for “%s”").printf (query));
            string q = query.casefold ();
            var queue = new Gee.ArrayQueue<string> ();
            queue.offer (root_path ());
            int visited = 0;
            while (!queue.is_empty && visited < 200 && page.items.size < 200) {
                string dir = queue.poll ();
                visited++;
                foreach (var it in yield list (dir, c)) {
                    if (it.kind == ItemKind.FOLDER) queue.offer (it.id.substring (4));
                    else if (it.title.casefold ().contains (q)) page.add (it);
                }
            }
            page.total = page.items.size;
            return page;
        }

        public async Playback resolve (MediaItem item, GLib.Cancellable? c) throws GLib.Error {
            if (!item.id.has_prefix ("file:")) throw new MediaError.NOT_FOUND (_("Unknown item"));
            return Playback.stream (GLib.File.new_for_path (item.id.substring (5)).get_uri ());
        }
    }
}
