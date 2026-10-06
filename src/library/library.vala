using Singularity.MediaSources;

namespace Singularity.Apps.Videos {

    public class VideoLibrary : GLib.Object {
        public const string SCHEMA = "dev.sinty.videos";

        public AppMediaHost host { get; private set; }
        public SourceRegistry registry { get; private set; }
        public MediaBin bin { get; private set; }
        public VideoBrowsePage browse { get; private set; }
        public EmbedPage embed { get; private set; }
        public LocalVideosSource local { get; private set; }

        private Singularity.AppPluginHost _plugins;
        private GLib.Settings? _settings = null;
        private VideoHistory _history;
        private weak Singularity.Widgets.Window _window;
        private GLib.Cancellable? _resolving = null;

        public signal void play_stream (string uri, GLib.HashTable<string, string>? headers, MediaItem? item, int64 start_ns);
        public signal void show_page (string name);
        public signal void message (string text);
        public signal void request (string what);
        public signal void address_failed (string uri);

        public VideoLibrary (Singularity.Widgets.Window window, VideoHistory history) {
            _window = window;
            _history = history;
            host = new AppMediaHost ("dev.sinty.videos", MediaKind.VIDEO, "Singularity-Videos/0.1");
            host.attach_window (window);
            host.message.connect ((source, text) => message (text));
            var source = GLib.SettingsSchemaSource.get_default ();
            if (source != null && source.lookup (SCHEMA, true) != null) {
                _settings = new GLib.Settings (SCHEMA);
                _settings.changed.connect ((key) => _sync_settings ());
            }
            _sync_settings ();

            bin = new MediaBin ();
            browse = new VideoBrowsePage ();
            embed = new EmbedPage ();
            browse.play_item.connect ((it) => play (it));
            browse.open_uri.connect ((uri) => open_uri (uri));
            browse.request.connect ((what) => {
                if (what == "browse-local") navigate (LocalVideosSource.ID, local.title);
                else if (what == "open-folder") {
                    GLib.DirUtils.create_with_parents (local.root_path (), 0755);
                    host.open_external (GLib.File.new_for_path (local.root_path ()).get_uri ());
                } else request (what);
            });
            embed.open_uri.connect ((uri) => open_uri (uri));
            embed.state_changed.connect (() => _save_embed_position ());

            _plugins = new Singularity.AppPluginHost ("dev.sinty.videos", "videos", Singularity.AppPluginHost.desktop_settings ());
            registry = new SourceRegistry (host, _plugins);
            registry.source_added.connect ((s) => {
                bin.add_source (s);
                s.changed.connect (() => browse.refresh_if_showing (s.id));
            });
            registry.source_removed.connect ((s) => {
                bin.remove_source (s.id);
                var cur = browse.current;
                if (cur != null && cur.source == s) show_page ("welcome");
            });
            local = new LocalVideosSource ();
            registry.add_builtin (local);

            bin.navigate.connect ((id, title) => navigate (id, title));
            bin.search_submitted.connect ((text) => search (text));
            bin.search_cleared.connect (() => {
                _cancel_typing ();
                browse.close_search ();
            });
            bin.search_typed.connect ((text) => {
                _cancel_typing ();
                if (text.length < 2 || _search_target ().id == "youtube") return;
                _typing_id = GLib.Timeout.add (600, () => {
                    _typing_id = 0;
                    search (text);
                    return GLib.Source.REMOVE;
                });
            });
            host.load_accounts.begin ();
            _plugins.load ();
        }

        private void _sync_settings () {
            if (_settings == null) return;
            string key = _settings.get_string ("youtube-api-key").strip ();
            host.set_value ("youtube", "api-key", key != "" ? key : null);
            host.set_value ("peertube", "instances", _settings.get_string ("peertube-instances"));
            host.set_value ("peertube", "search-index", _settings.get_string ("peertube-search-index"));
        }

        public bool open_in_browser {
            get { return _settings != null && _settings.get_boolean ("open-in-browser"); }
        }

        public void navigate (string id, string title) {
            bin.set_active (id);
            if (id == MediaBin.RECENT) {
                browse.recent_items = recent_items ();
                browse.open_root (null, null, _("Recent"));
            } else {
                var s = registry.find (id);
                if (s == null) return;
                browse.open_root (s, null, s.title);
            }
            show_page ("browse");
        }

        private uint _typing_id = 0;

        private void _cancel_typing () {
            if (_typing_id != 0) GLib.Source.remove (_typing_id);
            _typing_id = 0;
        }

        private MediaSource _search_target () {
            var cur = browse.current;
            MediaSource? s = cur != null ? cur.source : null;
            if (s == null) s = registry.find (bin.active);
            if (s == null || !(s is Searchable)) s = local;
            return s;
        }

        public void search (string text) {
            _cancel_typing ();
            var s = _search_target ();
            bin.set_active (s.id);
            browse.open_search (s, text);
            show_page ("browse");
        }

        public Gee.List<MediaItem> recent_items () {
            var list = new Gee.ArrayList<MediaItem> ();
            foreach (var e in _history.recent (40)) {
                MediaItem it;
                if (e.remote) {
                    it = new MediaItem (e.source_id, e.item_id, ItemKind.VIDEO, e.title);
                    it.image_url = e.image_url;
                    var s = registry.find (e.source_id);
                    if (s == null) continue;
                    it.subtitle = s.title;
                } else {
                    var f = GLib.File.new_for_uri (e.uri);
                    string? path = f.get_path ();
                    it = new MediaItem (LocalVideosSource.ID, "file:" + (path ?? e.uri), ItemKind.VIDEO, e.title);
                    if (path != null) it.set_extra ("thumbnail-file", path);
                }
                it.duration_ms = e.duration / 1000000;
                if (e.resumable && e.duration > 0) it.set_extra ("progress", ((double) e.position / e.duration).to_string ());
                list.add (it);
            }
            return list;
        }

        public static string? normalize_address (string text) {
            string t = text.strip ();
            if (t == "" || t.contains ("\n") || t.contains (" ")) return null;
            if (t.has_prefix ("/")) return GLib.File.new_for_path (t).get_uri ();
            if (t.has_prefix ("file://") || t.has_prefix ("http://") || t.has_prefix ("https://")) return t;
            if (t.has_prefix ("www.") || t.has_prefix ("youtu.be/") || t.has_prefix ("youtube.com/") || t.has_prefix ("m.youtube.com/")) return "https://" + t;
            return null;
        }

        private static bool _looks_like_media (string uri) {
            string path = uri;
            int q = path.index_of_char ('?');
            if (q >= 0) path = path.substring (0, q);
            if (path.down ().has_suffix (".m3u8") || path.down ().has_suffix (".mpd")) return true;
            return LocalVideosSource.is_video (path, null) || path.down ().has_suffix (".mp3") || path.down ().has_suffix (".ogg") || path.down ().has_suffix (".flac");
        }

        public async void open_address (string text) {
            string? uri = normalize_address (text);
            if (uri == null) {
                message (_("This is not a web address or a file."));
                return;
            }
            if (uri.has_prefix ("file://")) {
                var f = GLib.File.new_for_uri (uri);
                var it = new MediaItem (LocalVideosSource.ID, "file:" + (f.get_path () ?? uri), ItemKind.VIDEO, f.get_basename () ?? uri);
                play (it);
                return;
            }
            foreach (var s in registry.sources) {
                var klass = (GLib.ObjectClass) s.get_type ().class_ref ();
                if (klass.find_property ("handles-urls") == null) continue;
                bool handles = false;
                s.get ("handles-urls", out handles);
                var b = s as Browsable;
                if (!handles || b == null) continue;
                try {
                    var page = yield b.browse ("url:" + uri, null, null);
                    if (page.items.size == 0) continue;
                    var first = page.items[0];
                    if (page.items.size == 1 && first.playable) {
                        play (first);
                    } else {
                        bin.set_active (s.id);
                        browse.open_root (s, "url:" + uri, page.title);
                        show_page ("browse");
                    }
                    return;
                } catch (MediaError.NOT_FOUND e) {
                    if (e.message.has_prefix ("This is not")) continue;
                    message (e.message);
                    return;
                } catch (GLib.Error e) {
                    message (e.message);
                    return;
                }
            }
            bool media = _looks_like_media (uri);
            if (!media) {
                try {
                    var msg = new Soup.Message ("HEAD", uri);
                    if (msg != null) {
                        yield host.session.send_and_read_async (msg, GLib.Priority.DEFAULT, null);
                        string ctype = msg.response_headers.get_content_type (null) ?? "";
                        media = ctype.has_prefix ("video/") || ctype.has_prefix ("audio/") || ctype.contains ("mpegurl") || ctype == "application/dash+xml";
                    }
                } catch (GLib.Error e) {
                }
            }
            if (!media) {
                address_failed (uri);
                return;
            }
            play_stream (uri, null, null, -1);
        }

        public void open_uri (string uri) {
            if (uri == "settings:accounts" || uri == "settings:app") {
                try {
                    Singularity.Shell.ShellService shell = GLib.Bus.get_proxy_sync (GLib.BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                    if (uri == "settings:app") shell.open_app_settings ("dev.sinty.videos");
                    else shell.open_settings ("accounts");
                } catch (GLib.Error e) {
                    message (_("Settings are not available: %s").printf (e.message));
                }
                return;
            }
            host.open_external (uri);
        }

        public void play (MediaItem item) {
            if (item.source_id == LocalVideosSource.ID && item.id.has_prefix ("file:")) {
                play_stream (GLib.File.new_for_path (item.id.substring (5)).get_uri (), null, item, -1);
                return;
            }
            var source = registry.find (item.source_id);
            var resolver = source as PlaybackResolver;
            if (resolver == null) {
                if (item.external_url != "") open_uri (item.external_url);
                return;
            }
            if (open_in_browser && item.external_url != "") {
                open_uri (item.external_url);
                return;
            }
            if (_resolving != null) _resolving.cancel ();
            _resolving = new GLib.Cancellable ();
            var c = _resolving;
            resolver.resolve.begin (item, c, (o, r) => {
                Playback pb;
                try {
                    pb = resolver.resolve.end (r);
                } catch (GLib.IOError.CANCELLED e) {
                    return;
                } catch (GLib.Error e) {
                    message (e.message);
                    return;
                }
                if (c.is_cancelled ()) return;
                _start (item, pb);
            });
        }

        private int64 _resume_ms (string key) {
            var e = _history.find (key);
            if (e != null && e.resumable) return e.position / 1000000;
            return 0;
        }

        private void _start (MediaItem item, Playback pb) {
            string key = VideoHistory.remote_key (item.source_id, item.id);
            switch (pb.kind) {
                case PlaybackKind.STREAM: {
                    var headers = new GLib.HashTable<string, string> (str_hash, str_equal);
                    foreach (var name in pb.get_header_names ()) headers.insert (name, pb.get_header (name));
                    play_stream (pb.uri, headers, item, pb.start_ms > 0 ? pb.start_ms * 1000000 : -1);
                    break;
                }
                case PlaybackKind.EMBED:
                    if (pb.embed == null) {
                        open_uri (pb.uri != "" ? pb.uri : item.external_url);
                        break;
                    }
                    int64 start = pb.start_ms > 0 ? pb.start_ms : _resume_ms (key);
                    _history.record_item (key, start * 1000000, item.duration_ms * 1000000, item.title, item.source_id, item.id, item.image_url);
                    show_page ("embed");
                    embed.show_player (pb.embed, item, pb.uri, start);
                    break;
                case PlaybackKind.EXTERNAL:
                    open_uri (pb.uri != "" ? pb.uri : item.external_url);
                    break;
                default:
                    message (_("This source cannot play videos here."));
                    break;
            }
        }

        private void _save_embed_position () {
            var p = embed.player;
            var it = embed.item;
            if (p == null || it == null) return;
            int64 pos = p.position_ms;
            int64 dur = p.duration_ms;
            if (dur > 0 && pos >= dur - 15000) pos = 0;
            _history.record_item (VideoHistory.remote_key (it.source_id, it.id), pos * 1000000, dur * 1000000, it.title, it.source_id, it.id, it.image_url);
        }

        public void leave_embed () {
            _save_embed_position ();
            embed.release ();
        }

        public bool open_history_key (string key) {
            var e = _history.find (key);
            if (e == null || !e.remote) return false;
            var s = registry.find (e.source_id);
            if (s == null) {
                message (_("The source of this video is not available."));
                return true;
            }
            var it = new MediaItem (e.source_id, e.item_id, ItemKind.VIDEO, e.title);
            it.image_url = e.image_url;
            play (it);
            return true;
        }

        public void shutdown () {
            leave_embed ();
            registry.shutdown ();
        }
    }
}
