namespace Singularity.Apps.Videos {

    public interface MprisTarget : GLib.Object {
        public abstract bool mpris_playing { get; }
        public abstract bool mpris_loaded { get; }
        public abstract string mpris_uri { owned get; }
        public abstract string mpris_title { owned get; }
        public abstract int64 mpris_position { get; }
        public abstract int64 mpris_duration { get; }
        public abstract void mpris_set_playing (bool playing);
        public abstract void mpris_stop ();
        public abstract void mpris_seek_to (int64 position);
        public abstract void mpris_raise ();
        public abstract void mpris_open (string uri);
    }

    [DBus (name = "org.mpris.MediaPlayer2")]
    public class VideosMprisRoot : GLib.Object {
        private weak MprisTarget target;

        public VideosMprisRoot (MprisTarget target) {
            this.target = target;
        }

        public bool can_quit { get { return true; } }
        public bool can_raise { get { return true; } }
        public bool fullscreen { get { return false; } set {} }
        public bool can_set_fullscreen { get { return false; } }
        public bool has_track_list { get { return false; } }
        public string identity { owned get { return _("Videos"); } }
        public string desktop_entry { owned get { return "dev.sinty.videos"; } }
        public string[] supported_uri_schemes { owned get { return { "file", "http", "https" }; } }
        public string[] supported_mime_types { owned get { return { "video/mp4", "video/webm", "video/x-matroska", "video/quicktime", "video/ogg" }; } }

        public void raise () throws GLib.DBusError, GLib.IOError {
            target.mpris_raise ();
        }

        public void quit () throws GLib.DBusError, GLib.IOError {
            GLib.Application.get_default ()?.quit ();
        }
    }

    [DBus (name = "org.mpris.MediaPlayer2.Player")]
    public class VideosMprisPlayer : GLib.Object {
        private weak MprisTarget target;

        public signal void seeked (int64 position);

        public VideosMprisPlayer (MprisTarget target) {
            this.target = target;
        }

        public string playback_status {
            owned get {
                if (!target.mpris_loaded) return "Stopped";
                return target.mpris_playing ? "Playing" : "Paused";
            }
        }
        public string loop_status { owned get { return "None"; } set {} }
        public double rate { get { return 1.0; } set {} }
        public bool shuffle { get { return false; } set {} }
        public double volume { get { return 1.0; } set {} }
        public int64 position { get { return target.mpris_position / 1000; } }
        public double minimum_rate { get { return 1.0; } }
        public double maximum_rate { get { return 1.0; } }
        public bool can_go_next { get { return false; } }
        public bool can_go_previous { get { return false; } }
        public bool can_play { get { return target.mpris_loaded; } }
        public bool can_pause { get { return target.mpris_loaded; } }
        public bool can_seek { get { return target.mpris_loaded; } }
        public bool can_control { get { return true; } }

        public GLib.HashTable<string, GLib.Variant> metadata {
            owned get { return build_metadata (); }
        }

        public GLib.HashTable<string, GLib.Variant> build_metadata () {
            var meta = new GLib.HashTable<string, GLib.Variant> (str_hash, str_equal);
            if (!target.mpris_loaded) {
                meta["mpris:trackid"] = new GLib.Variant.object_path ("/org/mpris/MediaPlayer2/TrackList/NoTrack");
                return meta;
            }
            string uri = target.mpris_uri;
            meta["mpris:trackid"] = new GLib.Variant.object_path ("/dev/sinty/videos/Track/%u".printf (uri.hash ()));
            string shown = target.mpris_title;
            if (shown == "") {
                var file = GLib.File.new_for_uri (uri);
                string name = file.get_basename () ?? uri;
                int dot = name.last_index_of_char ('.');
                shown = dot > 0 ? name.substring (0, dot) : name;
            }
            meta["xesam:title"] = new GLib.Variant.string (shown);
            meta["xesam:url"] = new GLib.Variant.string (uri);
            if (target.mpris_duration > 0)
                meta["mpris:length"] = new GLib.Variant.int64 (target.mpris_duration / 1000);
            return meta;
        }

        public void next () throws GLib.DBusError, GLib.IOError {}
        public void previous () throws GLib.DBusError, GLib.IOError {}

        public void pause () throws GLib.DBusError, GLib.IOError {
            target.mpris_set_playing (false);
        }

        public void play_pause () throws GLib.DBusError, GLib.IOError {
            target.mpris_set_playing (!target.mpris_playing);
        }

        public void stop () throws GLib.DBusError, GLib.IOError {
            target.mpris_stop ();
        }

        public void play () throws GLib.DBusError, GLib.IOError {
            target.mpris_set_playing (true);
        }

        public void seek (int64 offset) throws GLib.DBusError, GLib.IOError {
            int64 pos = target.mpris_position + offset * 1000;
            if (pos < 0) pos = 0;
            if (target.mpris_duration > 0 && pos > target.mpris_duration) pos = target.mpris_duration;
            target.mpris_seek_to (pos);
            seeked (pos / 1000);
        }

        public void set_position (GLib.ObjectPath track_id, int64 position) throws GLib.DBusError, GLib.IOError {
            target.mpris_seek_to (position * 1000);
            seeked (position);
        }

        public void open_uri (string uri) throws GLib.DBusError, GLib.IOError {
            target.mpris_open (uri);
        }
    }

    public class VideosMpris : GLib.Object {
        private const string PATH = "/org/mpris/MediaPlayer2";

        private MprisTarget target;
        private VideosMprisRoot root;
        private VideosMprisPlayer player;
        private GLib.DBusConnection? conn = null;
        private uint owner_id = 0;
        private uint root_id = 0;
        private uint player_id = 0;
        private string last_status = "";
        private string last_uri = "";
        private int64 last_duration = 0;

        public VideosMpris (MprisTarget target) {
            this.target = target;
            root = new VideosMprisRoot (target);
            player = new VideosMprisPlayer (target);
        }

        public void start () {
            if (owner_id != 0) return;
            owner_id = GLib.Bus.own_name (GLib.BusType.SESSION, "org.mpris.MediaPlayer2.singularity-videos",
                GLib.BusNameOwnerFlags.NONE, (c) => {
                    conn = c;
                    try {
                        root_id = c.register_object (PATH, root);
                        player_id = c.register_object (PATH, player);
                    } catch (GLib.IOError e) {
                        warning ("videos mpris: %s", e.message);
                    }
                }, null, null);
        }

        public void stop () {
            if (conn != null) {
                if (root_id != 0) conn.unregister_object (root_id);
                if (player_id != 0) conn.unregister_object (player_id);
            }
            root_id = 0;
            player_id = 0;
            if (owner_id != 0) GLib.Bus.unown_name (owner_id);
            owner_id = 0;
            conn = null;
        }

        public void seeked (int64 position_ns) {
            player.seeked (position_ns / 1000);
        }

        public void update () {
            if (conn == null) return;
            string status = player.playback_status;
            string uri = target.mpris_loaded ? target.mpris_uri : "";
            int64 duration = target.mpris_duration;
            var changed = new GLib.VariantBuilder (new GLib.VariantType ("a{sv}"));
            bool any = false;
            if (status != last_status) {
                changed.add ("{sv}", "PlaybackStatus", new GLib.Variant.string (status));
                changed.add ("{sv}", "CanPlay", new GLib.Variant.boolean (target.mpris_loaded));
                changed.add ("{sv}", "CanPause", new GLib.Variant.boolean (target.mpris_loaded));
                changed.add ("{sv}", "CanSeek", new GLib.Variant.boolean (target.mpris_loaded));
                last_status = status;
                any = true;
            }
            if (uri != last_uri || duration != last_duration) {
                var meta = new GLib.VariantBuilder (new GLib.VariantType ("a{sv}"));
                player.build_metadata ().foreach ((k, v) => meta.add ("{sv}", k, v));
                changed.add ("{sv}", "Metadata", meta.end ());
                last_uri = uri;
                last_duration = duration;
                any = true;
            }
            if (!any) return;
            try {
                conn.emit_signal (null, PATH, "org.freedesktop.DBus.Properties", "PropertiesChanged",
                    new GLib.Variant ("(sa{sv}as)", "org.mpris.MediaPlayer2.Player", changed, new GLib.VariantBuilder (new GLib.VariantType ("as"))));
            } catch (GLib.Error e) {
                warning ("videos mpris: %s", e.message);
            }
        }
    }
}
