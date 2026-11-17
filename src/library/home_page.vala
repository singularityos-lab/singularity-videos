using Singularity.MediaSources;
using Singularity.Widgets;

namespace Singularity.Apps.Videos {

    public class VideoHomePage : Gtk.Box {
        private const int TILE_W = 224;
        private const int TILE_H = 126;

        public signal void play_item (MediaItem item);
        public signal void open_item (MediaItem item);

        private MediaHero _hero;
        private MediaShelf _recent;
        private MediaShelf _library;
        private MediaItem? _hero_item = null;
        private Gee.ArrayList<MediaItem> _recent_items = new Gee.ArrayList<MediaItem> ();
        private Gee.ArrayList<MediaItem> _library_items = new Gee.ArrayList<MediaItem> ();
        private GLib.Cancellable? _cancel = null;

        public bool has_content { get; private set; default = false; }

        public VideoHomePage () {
            Object (orientation: Gtk.Orientation.VERTICAL, spacing: 0);
            add_css_class ("videos-home");
            var scroll = new Gtk.ScrolledWindow ();
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroll.vexpand = true;
            var column = new Gtk.Box (Gtk.Orientation.VERTICAL, 28);
            column.margin_top = 16;
            column.margin_bottom = 24;
            column.margin_start = 24;
            column.margin_end = 24;
            var heading = new Gtk.Label (_("Home"));
            heading.xalign = 0;
            heading.add_css_class ("title-2");
            column.append (heading);

            _hero = new MediaHero ("folder-videos", 320, 180);
            _hero.eyebrow = _("Continue Watching");
            _hero.primary_clicked.connect (() => {
                if (_hero_item != null) play_item (_hero_item);
            });
            _hero.visible = false;
            column.append (_hero);

            _recent = new MediaShelf (_("Recently Watched"), TILE_W);
            _recent.tile_height = TILE_H;
            _recent.item_activated.connect ((i) => {
                if (i < _recent_items.size) play_item (_recent_items[(int) i]);
            });
            _recent.visible = false;
            column.append (_recent);

            _library = new MediaShelf (_("Your Videos"), TILE_W);
            _library.tile_height = TILE_H;
            _library.item_activated.connect ((i) => {
                if (i >= _library_items.size) return;
                var it = _library_items[(int) i];
                if (it.browsable) open_item (it);
                else play_item (it);
            });
            _library.visible = false;
            column.append (_library);

            scroll.set_child (column);
            append (scroll);
        }

        public async void load (Gee.List<MediaItem> recent, LocalVideosSource local) {
            if (_cancel != null) _cancel.cancel ();
            var cancel = new GLib.Cancellable ();
            _cancel = cancel;
            Gee.List<MediaItem> files = new Gee.ArrayList<MediaItem> ();
            try {
                files = (yield local.browse (null, null, cancel)).items;
            } catch (GLib.Error e) {
            }
            if (cancel.is_cancelled ()) return;
            _recent.clear ();
            _library.clear ();
            _recent_items.clear ();
            _library_items.clear ();
            _hero_item = null;
            foreach (var it in recent) {
                if (it.get_extra ("progress") != null) {
                    _hero_item = it;
                    break;
                }
            }
            if (_hero_item == null && recent.size > 0) _hero_item = recent[0];
            foreach (var it in recent) {
                if (it == _hero_item) continue;
                _recent_items.add (it);
                show (_recent.append_tile ("video-x-generic", it.title, it.subtitle, it.key), it);
            }
            foreach (var it in files) {
                _library_items.add (it);
                string icon = it.kind == ItemKind.FOLDER ? "folder-videos" : "video-x-generic";
                show (_library.append_tile (icon, it.title, it.subtitle, it.key), it);
            }
            if (_hero_item == null && _library_items.size > 0) {
                foreach (var it in _library_items) {
                    if (it.playable) {
                        _hero_item = it;
                        break;
                    }
                }
            }
            _hero.visible = _hero_item != null;
            if (_hero_item != null) {
                bool resume = _hero_item.get_extra ("progress") != null;
                _hero.eyebrow = resume ? _("Continue Watching") : _("Your Videos");
                _hero.primary_label = resume ? _("Resume") : _("Play");
                _hero.title = _hero_item.title;
                _hero.subtitle = resume ? _left (_hero_item) : _hero_item.subtitle;
                _hero.art.paintable = null;
                show (_hero.art, _hero_item);
            }
            _recent.visible = _recent_items.size > 0;
            _library.visible = _library_items.size > 0;
            has_content = _hero_item != null || _library_items.size > 0;
        }

        private static string _left (MediaItem it) {
            double done = double.parse (it.get_extra ("progress") ?? "0");
            int64 ms = (int64) (it.duration_ms * (1.0 - done));
            if (it.duration_ms <= 0 || ms <= 0) return it.subtitle;
            int minutes = (int) ((ms + 59999) / 60000);
            if (minutes < 60) return ngettext ("%d minute left", "%d minutes left", minutes).printf (minutes);
            return _("%d h %d min left").printf (minutes / 60, minutes % 60);
        }

        private static void show (MediaArt art, MediaItem it) {
            string? progress = it.get_extra ("progress");
            art.progress = progress != null ? double.parse (progress) : -1;
            Thumbnails.Ready ready = (tex) => art.paintable = tex;
            if (it.image_url != "") {
                Thumbnails.get_default ().load_url (it.image_url, (owned) ready);
            } else if (it.get_extra ("thumbnail-file") != null) {
                Thumbnails.get_default ().load_video_frame (it.get_extra ("thumbnail-file"), it.get_extra ("modified") ?? "", (owned) ready);
            }
        }

        public void focus_start () {
            if (_hero.visible) _hero.focus_primary ();
        }
    }
}
