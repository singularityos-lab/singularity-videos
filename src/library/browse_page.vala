using Singularity.MediaSources;

namespace Singularity.Apps.Videos {

    public class BrowseLevel : GLib.Object {
        public MediaSource? source;
        public string? node;
        public string title;
        public string? query;
        public Gee.ArrayList<MediaItem> items = new Gee.ArrayList<MediaItem> ();
        public string? next_token = null;
        public int total = -1;
        public double scroll = 0;

        public BrowseLevel (MediaSource? source, string? node, string title, string? query = null) {
            this.source = source;
            this.node = node;
            this.title = title;
            this.query = query;
        }
    }

    public class VideoBrowsePage : Gtk.Box {

        private Gee.ArrayList<BrowseLevel> _levels = new Gee.ArrayList<BrowseLevel> ();
        private Gtk.Button _back;
        private Gtk.Label _title;
        private Gtk.Label _count;
        private Gtk.Stack _stack;
        private Gtk.ScrolledWindow _scroll;
        private Gtk.FlowBox _grid;
        private Singularity.Widgets.StatusPage _status;
        private Gtk.Button _status_action;
        private string _status_uri = "";
        private GLib.Cancellable? _cancel = null;
        private uint _generation = 0;
        private bool _loading_more = false;

        public signal void play_item (MediaItem item);
        public signal void open_uri (string uri);
        public signal void level_changed ();
        public signal void request (string what);

        public Gee.List<MediaItem>? recent_items = null;

        construct {
            orientation = Gtk.Orientation.VERTICAL;
            spacing = 0;
            hexpand = true;
            vexpand = true;
            add_css_class ("videos-browse");

            var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            header.add_css_class ("videos-browse-header");
            header.margin_start = 24;
            header.margin_end = 24;
            header.margin_bottom = 8;
            Singularity.Widgets.apply_view_edge (header);
            _back = new Gtk.Button.from_icon_name ("go-previous-symbolic");
            _back.add_css_class ("flat");
            _back.tooltip_text = _("Back (Alt+Left)");
            _back.valign = Gtk.Align.CENTER;
            _back.clicked.connect (() => go_back ());
            header.append (_back);
            var titles = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
            titles.hexpand = true;
            titles.valign = Gtk.Align.CENTER;
            _title = new Gtk.Label ("");
            _title.add_css_class ("title-2");
            _title.xalign = 0;
            _title.ellipsize = Pango.EllipsizeMode.END;
            _count = new Gtk.Label ("");
            _count.add_css_class ("dim-label");
            _count.xalign = 0;
            titles.append (_title);
            titles.append (_count);
            header.append (titles);
            append (header);

            _stack = new Gtk.Stack ();
            _stack.vexpand = true;
            _stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
            _stack.transition_duration = 150;

            _grid = new Gtk.FlowBox ();
            _grid.selection_mode = Gtk.SelectionMode.NONE;
            _grid.homogeneous = true;
            _grid.halign = Gtk.Align.START;
            _grid.min_children_per_line = 1;
            _grid.max_children_per_line = 8;
            _grid.column_spacing = 16;
            _grid.row_spacing = 20;
            _grid.valign = Gtk.Align.START;
            _grid.activate_on_single_click = true;
            _grid.add_css_class ("videos-grid");
            _grid.child_activated.connect ((child) => _activate (child.get_data<MediaItem> ("item")));
            var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            content.margin_start = 24;
            content.margin_end = 24;
            content.margin_top = 8;
            content.margin_bottom = 24;
            content.append (_grid);
            _scroll = new Gtk.ScrolledWindow ();
            _scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            _scroll.vexpand = true;
            _scroll.child = content;
            _scroll.edge_reached.connect ((pos) => {
                if (pos == Gtk.PositionType.BOTTOM) _load_more.begin ();
            });
            _stack.add_named (_scroll, "items");

            var spinner = new Gtk.Spinner ();
            spinner.spinning = true;
            spinner.set_size_request (32, 32);
            spinner.halign = Gtk.Align.CENTER;
            spinner.valign = Gtk.Align.CENTER;
            _stack.add_named (spinner, "loading");

            _status = new Singularity.Widgets.StatusPage ();
            _status.vexpand = true;
            _status_action = new Gtk.Button.with_label ("");
            _status_action.add_css_class ("pill");
            _status_action.halign = Gtk.Align.CENTER;
            _status_action.clicked.connect (() => {
                if (_status_uri == "retry") reload ();
                else if (_status_uri != "") open_uri (_status_uri);
            });
            _status.child = _status_action;
            _stack.add_named (_status, "status");
            _stack.add_named (new Gtk.Box (Gtk.Orientation.VERTICAL, 0), "section");
            append (_stack);
            _update_header ();
        }

        public BrowseLevel? current {
            owned get { return _levels.size > 0 ? _levels[_levels.size - 1] : null; }
        }

        public bool can_go_back {
            get { return _levels.size > 1; }
        }

        public void open_root (MediaSource? source, string? node, string title) {
            _levels.clear ();
            _push (new BrowseLevel (source, node, title));
        }

        public void open_search (MediaSource source, string query) {
            BrowseLevel? base_level = null;
            foreach (var l in _levels) if (l.query == null) base_level = l;
            _levels.clear ();
            if (base_level != null) _levels.add (base_level);
            _push (new BrowseLevel (source, null, _("Results for “%s”").printf (query), query));
        }

        public void close_search () {
            if (current != null && current.query != null) go_back ();
        }

        private void _push (BrowseLevel level) {
            if (current != null) current.scroll = _scroll.vadjustment.value;
            _levels.add (level);
            reload ();
        }

        public void go_back () {
            if (_levels.size <= 1) return;
            _levels.remove_at (_levels.size - 1);
            var level = current;
            double scroll = level.scroll;
            if (level.items.size > 0) {
                _render ();
                GLib.Idle.add (() => {
                    _scroll.vadjustment.value = scroll;
                    return GLib.Source.REMOVE;
                });
                _update_header ();
            } else {
                reload ();
            }
            level_changed ();
        }

        public void reload () {
            var level = current;
            if (level == null) return;
            level.items.clear ();
            level.next_token = null;
            level.total = -1;
            if (_cancel != null) _cancel.cancel ();
            _cancel = new GLib.Cancellable ();
            _generation++;
            _update_header ();
            _stack.visible_child_name = "loading";
            _fetch.begin (level, null, _cancel, _generation);
            level_changed ();
        }

        public void refresh_if_showing (string source_id) {
            if (current != null && current.source != null && current.source.id == source_id) reload ();
        }

        private async MediaPage _page (BrowseLevel level, string? token, GLib.Cancellable c) throws GLib.Error {
            if (level.source == null) {
                var page = new MediaPage (level.title);
                if (recent_items != null) foreach (var it in recent_items) page.add (it);
                page.total = page.items.size;
                return page;
            }
            if (level.query != null) {
                var s = level.source as Searchable;
                if (s == null) throw new MediaError.UNSUPPORTED (_("This source cannot search"));
                return yield s.search (level.query, MediaKind.VIDEO, token, c);
            }
            var b = level.source as Browsable;
            if (b == null) throw new MediaError.UNSUPPORTED (_("This source cannot be browsed"));
            return yield b.browse (level.node, token, c);
        }

        private async void _fetch (BrowseLevel level, string? token, GLib.Cancellable c, uint generation) {
            try {
                var page = yield _page (level, token, c);
                if (generation != _generation || level != current) return;
                if (token == null && page.title != "" && level.query == null && level.node != null) level.title = page.title;
                level.items.add_all (page.items);
                level.next_token = page.next_token;
                level.total = page.total;
                if (token == null && page.items.size == 0) {
                    if (level.query != null) {
                        _show_status ("system-search", _("No Results"), _("Try other words."), "", "");
                    } else if (level.source == null) {
                        _show_section ("document-open-recent", _("Recent"), _("Videos you watch appear here."), {
                            "folder-open|" + _("Open Video") + "|" + _("Play a video from your device") + "|open-file",
                            "folder-videos|" + _("Browse Your Videos") + "|" + _("See the videos in your Videos folder") + "|browse-local"
                        });
                    } else if (level.node == null && level.source.id == LocalVideosSource.ID) {
                        _show_section ("folder-videos", _("Videos"), page.notice != "" ? page.notice : _("Your Videos folder is empty."), {
                            "folder-open|" + _("Open Video") + "|" + _("Play a video from anywhere on your device") + "|open-file",
                            "folder-videos|" + _("Open Videos Folder") + "|" + _("Add videos to the folder in Files") + "|open-folder"
                        });
                    } else if (level.node == null && page.action_uri != "") {
                        string icon = page.action_uri == "settings:app" ? "applications-engineering" : "singularity-account-generic";
                        string label = page.action_uri == "settings:app" ? _("Open Settings") : _("Open Online Accounts");
                        string desc = page.action_uri == "settings:app" ? _("Change the settings of Videos") : _("Add an account and switch on Videos");
                        _show_section ("video-x-generic", level.source.title, page.notice, { icon + "|" + label + "|" + desc + "|" + page.action_uri });
                    } else {
                        _show_status ("folder-videos", _("Nothing Here"), page.notice, page.action_label, page.action_uri);
                    }
                    if (_stack.visible_child_name != "section") _update_header ();
                    return;
                }
                if (token == null) _render ();
                else _append (page.items);
                _update_header ();
            } catch (GLib.IOError.CANCELLED e) {
            } catch (GLib.Error e) {
                if (generation != _generation || token != null) return;
                if (e is MediaError.NEEDS_ACCOUNT || e is MediaError.AUTH_FAILED) {
                    _show_status ("dialog-password", _("Sign-In Needed"), e.message, _("Online Accounts"), "settings:accounts");
                    return;
                }
                if (e is MediaError.NOT_CONFIGURED) {
                    _show_status ("applications-engineering", _("Setup Needed"), e.message, _("Settings"), "settings:app");
                    return;
                }
                if (e is MediaError.RATE_LIMITED) {
                    _show_status ("dialog-warning", _("Too Many Requests"), e.message, _("Try Again"), "retry");
                    return;
                }
                _show_status ("network-error", _("Could Not Load"), e.message, _("Try Again"), "retry");
            }
        }

        private void _show_status (string icon, string title, string text, string action_label, string action_uri) {
            _status.icon_name = icon;
            _status.title = title;
            _status.description = text;
            _status_uri = action_uri;
            _status_action.label = action_label;
            _status_action.visible = action_label != "";
            _stack.visible_child_name = "status";
        }

        private void _show_section (string icon, string title, string subtitle, string[] actions) {
            var old = _stack.get_child_by_name ("section");
            if (old != null) _stack.remove (old);
            var wp = new Singularity.Widgets.WelcomePage ();
            wp.is_section = true;
            wp.app_icon_name = icon;
            wp.title = title;
            wp.subtitle = subtitle;
            foreach (var spec in actions) {
                var parts = spec.split ("|", 4);
                string what = parts[3];
                wp.add_action (parts[0], parts[1], parts[2], () => {
                    if (what.has_prefix ("settings:")) open_uri (what);
                    else request (what);
                });
            }
            _stack.add_named (wp, "section");
            _stack.visible_child_name = "section";
            _title.label = "";
            _count.label = "";
        }

        private async void _load_more () {
            var level = current;
            if (level == null || _loading_more || level.next_token == null || _cancel == null) return;
            _loading_more = true;
            yield _fetch (level, level.next_token, _cancel, _generation);
            _loading_more = false;
        }

        private void _render () {
            Gtk.Widget? c;
            while ((c = _grid.get_first_child ()) != null) _grid.remove (c);
            _append (current.items);
            _stack.visible_child_name = "items";
            _scroll.vadjustment.value = 0;
        }

        private void _append (Gee.List<MediaItem> items) {
            foreach (var it in items) _grid.append (_tile (it));
        }

        private static string _icon_for (MediaItem it) {
            switch (it.kind) {
                case ItemKind.CHANNEL: return "avatar-default";
                case ItemKind.PLAYLIST: return "video-x-generic";
                case ItemKind.FOLDER: return "folder-videos";
                default: return "video-x-generic";
            }
        }

        private Gtk.Widget _tile (MediaItem it) {
            var child = new Gtk.FlowBoxChild ();
            child.set_data<MediaItem> ("item", it);
            child.add_css_class ("videos-tile");
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
            box.width_request = PosterFrame.WIDTH;
            box.halign = Gtk.Align.CENTER;
            box.valign = Gtk.Align.START;
            box.margin_top = 6;
            box.margin_bottom = 6;
            box.margin_start = 6;
            box.margin_end = 6;

            var frame = new Gtk.Overlay ();
            frame.halign = Gtk.Align.START;
            var poster = new PosterFrame ();
            var icon = new Gtk.Image.from_icon_name (_icon_for (it));
            icon.pixel_size = 64;
            icon.halign = Gtk.Align.CENTER;
            icon.valign = Gtk.Align.CENTER;
            frame.child = poster;
            frame.add_overlay (icon);
            if (!it.kind.is_container ()) poster.add_css_class ("videos-poster-video");

            Thumbnails.Ready show = (tex) => {
                poster.paintable = tex;
                icon.visible = false;
                poster.add_css_class ("videos-poster-video");
            };
            if (it.image_url != "") {
                Thumbnails.get_default ().load_url (it.image_url, (owned) show);
            } else if (it.get_extra ("thumbnail-file") != null) {
                Thumbnails.get_default ().load_video_frame (it.get_extra ("thumbnail-file"), it.get_extra ("modified") ?? "", (owned) show);
            }

            if (it.duration_ms > 0 || it.get_extra ("live") == "true") {
                var badge = new Gtk.Label (it.get_extra ("live") == "true" ? _("Live") : it.display_duration ());
                badge.add_css_class ("videos-duration");
                badge.add_css_class ("numeric");
                badge.halign = Gtk.Align.END;
                badge.valign = Gtk.Align.END;
                badge.margin_end = 6;
                badge.margin_bottom = 6;
                frame.add_overlay (badge);
            }
            if (it.get_extra ("progress") != null) {
                var bar = new Gtk.ProgressBar ();
                bar.fraction = double.parse (it.get_extra ("progress"));
                bar.valign = Gtk.Align.END;
                bar.add_css_class ("videos-progress");
                frame.add_overlay (bar);
            }
            box.append (frame);

            var title = new Gtk.Label (it.title);
            title.ellipsize = Pango.EllipsizeMode.END;
            title.lines = 2;
            title.wrap = true;
            title.wrap_mode = Pango.WrapMode.WORD_CHAR;
            title.max_width_chars = 22;
            title.width_chars = 22;
            title.xalign = 0;
            title.yalign = 0;
            title.margin_top = 4;
            title.add_css_class ("heading");
            box.append (title);
            string sub = it.subtitle;
            if (it.attribution != "" && it.attribution != sub && it.kind == ItemKind.VIDEO && it.source_id != LocalVideosSource.ID) {
                sub = sub != "" ? "%s, %s".printf (sub, it.attribution) : it.attribution;
            }
            if (sub != "") {
                var s = new Gtk.Label (sub);
                s.ellipsize = Pango.EllipsizeMode.END;
                s.max_width_chars = 22;
                s.width_chars = 22;
                s.xalign = 0;
                s.add_css_class ("dim-label");
                s.add_css_class ("caption");
                box.append (s);
            }
            child.child = box;
            child.tooltip_text = it.subtitle != "" ? "%s\n%s".printf (it.title, it.subtitle) : it.title;
            _attach_menu (child, it);
            return child;
        }

        private void _attach_menu (Gtk.Widget w, MediaItem it) {
            var click = new Gtk.GestureClick ();
            click.button = Gdk.BUTTON_SECONDARY;
            click.pressed.connect ((n, x, y) => {
                var menu = new Singularity.Widgets.ContextMenu (w);
                Gdk.Rectangle rect = { (int) x, (int) y, 1, 1 };
                menu.set_pointing_to (rect);
                if (it.playable) menu.add_item (_("Play"), "media-playback-start-symbolic", () => _activate (it));
                if (it.browsable) menu.add_item (_("Open"), "go-next-symbolic", () => _activate (it));
                if (it.external_url != "") {
                    menu.add_separator ();
                    menu.add_item (it.external_label != "" ? it.external_label : _("Open in Browser"), "web-browser-symbolic", () => open_uri (it.external_url));
                }
                menu.popup ();
            });
            w.add_controller (click);
        }

        private void _activate (MediaItem? it) {
            if (it == null) return;
            if (it.browsable) {
                var level = current;
                _push (new BrowseLevel (level != null ? level.source : null, it.id, it.title));
                return;
            }
            if (!it.playable) {
                if (it.external_url != "") open_uri (it.external_url);
                return;
            }
            play_item (it);
        }

        private void _update_header () {
            var level = current;
            _back.visible = can_go_back;
            if (level == null) {
                _title.label = "";
                _count.label = "";
                return;
            }
            _title.label = level.title;
            int n = level.total >= 0 ? level.total : level.items.size;
            int videos = 0;
            foreach (var x in level.items) if (x.playable) videos++;
            if (n <= 0 || level.items.size == 0) _count.label = "";
            else if (videos == level.items.size) _count.label = ngettext ("%d video", "%d videos", n).printf (n);
            else _count.label = ngettext ("%d item", "%d items", n).printf (n);
            _count.visible = _count.label != "";
        }
    }
}
