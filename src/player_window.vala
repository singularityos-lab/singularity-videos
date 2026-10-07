namespace Singularity.Apps.Videos {

    [GtkTemplate (ui = "/dev/sinty/videos/ui/player.ui")]
    public class PlayerWindow : Singularity.Widgets.Window, MprisTarget {

        [GtkChild] unowned Gtk.Overlay     player_overlay;
        [GtkChild] unowned Gtk.Picture     video_picture;
        [GtkChild] unowned Gtk.Box         overlay_box;
        [GtkChild] unowned Gtk.Box         controls_box;
        [GtkChild] unowned Gtk.Box         seek_slot;
        [GtkChild] unowned Gtk.Label       elapsed_lbl;
        [GtkChild] unowned Gtk.Button      remaining_btn;
        [GtkChild] unowned Gtk.MenuButton  volume_btn;
        [GtkChild] unowned Gtk.Button      play_btn;
        [GtkChild] unowned Gtk.MenuButton  tracks_btn;
        [GtkChild] unowned Gtk.MenuButton  speed_btn;
        [GtkChild] unowned Gtk.Button      fullscreen_btn;

        private const int64 SKIP_NS = 10000000000;
        private const uint HIDE_DELAY_MS = 2500;
        private const double[] RATES = { 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0 };

        private Gtk.Stack _stack;
        private GstPlayer _player;
        private SeekBar _seek;
        private Singularity.Widgets.Clamp _controls_clamp;
        private Singularity.Widgets.StatusPage _error_page;
        private Gtk.Widget? _bubble_row = null;
        private Gtk.Scale _volume_scale;
        private Gtk.Label _volume_value;
        private Gtk.Label _speed_label;

        private bool _is_playing = false;
        private Singularity.Widgets.LiveTextSession? _live_text = null;
        private bool _chrome_visible = true;
        private bool _pointer_on_controls = false;
        private bool _show_remaining = true;
        private bool _syncing_volume = false;
        private uint _hide_timer_id = 0;
        private uint _pos_timer_id = 0;
        private uint _click_timer_id = 0;
        private int64 _last_scrub = 0;
        private double _last_x = -1;
        private double _last_y = -1;
        private string _tracks_sig = "";
        private Singularity.Animation.TimedAnimation? _fade = null;

        private Gtk.FileChooserNative? _open_dialog = null;

        private string _uri = "";
        private VideoHistory _history = new VideoHistory ();
        private VideosMpris _mpris;
        private uint _ticks = 0;
        private uint _resume_id = 0;

        private GLib.SimpleAction[] _media_actions = {};
        private GLib.SimpleAction _mute_action;
        private GLib.SimpleAction _rate_action;
        private GLib.SimpleAction _subtitle_action;
        private GLib.SimpleAction _audio_action;
        private Gtk.Button _share_btn;
        private Gtk.Button _open_btn;
        private Gtk.Button _trim_btn;
        private Gtk.Button _trim_done_btn;
        private Gtk.Button _trim_export_btn;
        private TrimView? _trim = null;
        private VideoLibrary _library;
        private Gtk.Button _sidebar_btn;
        private Gtk.Button _embed_back_btn;
        private Gtk.Button _browser_btn;
        private bool _sidebar_wanted = true;
        private string _stream_uri = "";
        private Singularity.MediaSources.MediaItem? _stream_item = null;

        public PlayerWindow (Gtk.Application app) {
            GLib.Object (application: app);
            default_width  = 960;
            default_height = 540;
            title          = _("Videos");
            add_css_class ("videos-window");

            _player = new GstPlayer ();
            _player.error_occurred.connect (_on_error);
            _player.finished.connect (() => {
                _record (0, _player.duration_ns ());
                _is_playing = false;
                _update_play_icon ();
                _poke ();
                _mpris.update ();
            });
            _player.tracks_changed.connect (_rebuild_tracks);
            _mpris = new VideosMpris (this);
            _mpris.start ();

            _build_ui ();
            _setup_actions ();
            _connect_signals ();
            _sync_trim_bubbles ();
        }

        private GLib.SimpleAction _add_win_action (string name, owned Singularity.Widgets.Window.BubbleAction func) {
            var act = new GLib.SimpleAction (name, null);
            act.activate.connect (() => func ());
            add_action (act);
            return act;
        }

        private void _setup_actions () {
            _add_win_action ("close", () => close ());
            _add_win_action ("trim", () => enter_trim ());
            _add_win_action ("sidebar", () => _toggle_sidebar ());
            _add_win_action ("open-address", () => open_address_dialog ());

            _add_win_action ("search", () => {
                if (_on_trim ()) return;
                _sidebar_wanted = true;
                set_sidebar_visible (true);
                _library.bin.focus_search ();
            });
            _media_actions += _add_win_action ("play-pause", () => _toggle_play ());
            _media_actions += _add_win_action ("stop", () => _stop ());
            _media_actions += _add_win_action ("skip-back", () => _skip (-SKIP_NS));
            _media_actions += _add_win_action ("skip-forward", () => _skip (SKIP_NS));
            _media_actions += _add_win_action ("volume-up", () => _set_volume (_player.volume + 0.05));
            _media_actions += _add_win_action ("volume-down", () => _set_volume (_player.volume - 0.05));
            var share = Singularity.Share.add_action (this, this, () => {
                if (_uri == "") return null;
                if (_stream_item != null) {
                    if (_stream_item.external_url == "") return null;
                    return new Singularity.ShareContent.for_uris ({ _stream_item.external_url }, _stream_item.title);
                }
                if (_uri.has_prefix ("file://")) return new Singularity.ShareContent.for_files ({ GLib.File.new_for_uri (_uri) });
                return new Singularity.ShareContent.for_uris ({ _uri }, GLib.File.new_for_uri (_uri).get_basename ());
            });
            share.bind_property ("enabled", _share_btn, "visible", GLib.BindingFlags.SYNC_CREATE);
            _media_actions += share;
            _media_actions += _add_win_action ("add-moment", () => {
                if (_uri == "") return;
                string target = _stream_item != null ? _stream_item.external_url : _uri;
                if (target == "" || target.has_prefix ("videos-source:")) return;
                int seconds = (int) (_player.position_ns () / 1000000000);
                string title = _stream_item != null ? _stream_item.title : GLib.File.new_for_uri (_uri).get_basename ();
                Singularity.Notes.NotePicker.popup (video_picture, (id) => _add_moment (target, title, seconds, id));
            });

            _mute_action = new GLib.SimpleAction.stateful ("mute", null, new GLib.Variant.boolean (false));
            _mute_action.activate.connect (() => _toggle_mute ());
            add_action (_mute_action);
            _media_actions += _mute_action;

            _rate_action = new GLib.SimpleAction.stateful ("rate", GLib.VariantType.DOUBLE, new GLib.Variant.double (1.0));
            _rate_action.activate.connect ((param) => _set_rate (param.get_double ()));
            add_action (_rate_action);
            _media_actions += _rate_action;

            _subtitle_action = new GLib.SimpleAction.stateful ("subtitle", GLib.VariantType.INT32, new GLib.Variant.int32 (-1));
            _subtitle_action.activate.connect ((param) => {
                _player.current_subtitle = param.get_int32 ();
                _subtitle_action.set_state (param);
            });
            add_action (_subtitle_action);

            _audio_action = new GLib.SimpleAction.stateful ("audio-track", GLib.VariantType.INT32, new GLib.Variant.int32 (0));
            _audio_action.activate.connect ((param) => {
                _player.current_audio = param.get_int32 ();
                _audio_action.set_state (param);
            });
            add_action (_audio_action);

            var fullscreen = new GLib.SimpleAction.stateful ("fullscreen", null, new GLib.Variant.boolean (false));
            fullscreen.activate.connect (() => _toggle_fullscreen ());
            notify["fullscreened"].connect (() => {
                fullscreen.set_state (new GLib.Variant.boolean (fullscreened));
                fullscreen_btn.icon_name = fullscreened ? "view-restore-symbolic" : "view-fullscreen-symbolic";
                fullscreen_btn.tooltip_text = fullscreened ? _("Leave Fullscreen") : _("Fullscreen");
                _poke ();
            });
            add_action (fullscreen);
            _update_media_actions ();
            _sync_volume ();
        }

        private void _update_media_actions () {
            bool loaded = _on_player ();
            foreach (var act in _media_actions) act.set_enabled (loaded);
        }

        private void _build_ui () {
            _sidebar_btn = add_bubble_icon ("sidebar-show-symbolic", _("Sidebar (F9)"), () => _toggle_sidebar ());
            _embed_back_btn = add_bubble_icon ("go-previous-symbolic", _("Back to Library"), () => _back_to_library ());
            _embed_back_btn.visible = false;
            var open_btn = add_bubble_icon ("document-open-symbolic", _("Open Video"),
                                            () => open_file_dialog ());
            _open_btn = open_btn;
            _trim_btn = add_bubble_icon ("edit-cut-symbolic", _("Trim"),
                                         () => enter_trim ());
            _share_btn = add_bubble_icon ("singularity-share-symbolic", _("Share"),
                                          () => ((GLib.ActionGroup) this).activate_action ("share", null));
            _trim_done_btn = add_bubble_icon ("go-previous-symbolic", _("Close Trim"), () => _close_trim ());
            _trim_export_btn = add_bubble_suggested (_("Export…"), () => _export_trim ());
            _browser_btn = add_bubble_icon ("web-browser-symbolic", _("Open in Browser"), () => {
                if (_library.embed.external_uri != "") _library.open_uri (_library.embed.external_uri);
            });
            _browser_btn.visible = false;
            _trim_done_btn.visible = false;
            _trim_export_btn.visible = false;
            for (Gtk.Widget? w = open_btn; w != null; w = w.get_parent ()) {
                if (w.has_css_class ("singularity-hover-controls")) {
                    _bubble_row = w;
                    break;
                }
            }

            _stack = new Gtk.Stack ();
            _stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
            _stack.hexpand = true;
            _stack.vexpand = true;

            _stack.add_named (_build_welcome_page (), "welcome");
            _stack.add_named (_build_player_page (), "player");
            _stack.add_named (_build_error_page (), "error");

            _library = new VideoLibrary (this, _history);
            _stack.add_named (_library.browse, "browse");
            _stack.add_named (_library.embed, "embed");
            _library.show_page.connect ((name) => _show_page (name));
            _library.message.connect ((text) => add_toast (new Singularity.Widgets.Toast (text)));
            _library.play_stream.connect ((uri, headers, item, start) => _play_stream (uri, headers, item, start));
            _library.embed.state_changed.connect (() => _mpris.update ());
            set_sidebar (_library.bin);
            _library.bin.open_files.connect (() => open_file_dialog ());
            _library.bin.open_address.connect (() => open_address_dialog ());
            _library.address_failed.connect ((uri) => {
                var toast = new Singularity.Widgets.Toast (_("Videos cannot play this address"));
                toast.button_label = _("Open in Browser");
                toast.button_clicked.connect (() => _library.host.open_external (uri));
                add_toast (toast);
            });
            _library.request.connect ((what) => {
                if (what == "open-file") open_file_dialog ();
            });

            set_content (_stack);
            set_bubbles_on_hover (false);
        }

        private Gtk.Widget _build_welcome_page () {
            var wp = new Singularity.Widgets.WelcomePage ();
            wp.app_icon_name = "dev.sinty.videos";
            wp.title         = _("Videos");
            if (_player.paintable == null) {
                wp.subtitle = _("Missing video sink. Install gstreamer1.0-gtk4 and restart.");
            } else {
                wp.subtitle = _("Watch movies, shows, and clips");
            }
            wp.add_action (
                "folder-open",
                _("Open Video"),
                _("Open a video or audio file from your device"),
                () => open_file_dialog ()
            );
            wp.add_action (
                "video-trim",
                _("Trim a Video"),
                _("Cut, crop and join clips, then export them for the web"),
                () => enter_trim ()
            );
            wp.add_action (
                "singularity-share-link",
                _("Open Address"),
                _("Play a YouTube or PeerTube link, or a video on the web"),
                () => open_address_dialog ()
            );
            wp.add_action (
                "singularity-account-generic",
                _("Add a Video Service"),
                _("Connect YouTube, Jellyfin or Nextcloud in Online Accounts"),
                () => _library.open_uri ("settings:accounts")
            );
            return wp;
        }

        private Gtk.Widget _build_error_page () {
            _error_page = new Singularity.Widgets.StatusPage ();
            _error_page.icon_name = "video-x-generic";
            _error_page.title = _("Can't Play This Video");
            var again = new Gtk.Button.with_label (_("Open Another Video"));
            again.add_css_class ("suggested-action");
            again.add_css_class ("pill");
            again.halign = Gtk.Align.CENTER;
            again.clicked.connect (() => open_file_dialog ());
            _error_page.child = again;
            return _error_page;
        }

        private Gtk.Widget _build_player_page () {
            player_overlay.add_css_class ("videos-player");
            if (Singularity.TextRecognition.Recognizer.get_default ().available) {
                _live_text = new Singularity.Widgets.LiveTextSession ();
                _live_text.view.set_geometry_func ((out ox, out oy, out scale) => _frame_geometry (out ox, out oy, out scale));
                player_overlay.add_overlay (_live_text.view);
                _live_text.toggle.add_css_class ("singularity-hover-btn");
                _live_text.toggle.halign = Gtk.Align.END;
                _live_text.toggle.valign = Gtk.Align.START;
                _live_text.toggle.margin_top = 64;
                _live_text.toggle.margin_end = 12;
                _live_text.toggle.visible = false;
                player_overlay.add_overlay (_live_text.toggle);
                _live_text.bar.valign = Gtk.Align.START;
                _live_text.bar.margin_top = 64;
                player_overlay.add_overlay (_live_text.bar);
                player_overlay.add_css_class ("singularity-hover-on-content");
            }
            if (_player.paintable != null) {
                video_picture.set_paintable (_player.paintable);
                _player.paintable.invalidate_size.connect (() => _auto_resize ());
            }

            play_btn.add_css_class ("videos-ctrl");
            speed_btn.add_css_class ("videos-ctrl");
            remaining_btn.add_css_class ("videos-time");

            overlay_box.remove (controls_box);
            _controls_clamp = new Singularity.Widgets.Clamp (controls_box, 720);
            _controls_clamp.margin_start = 16;
            _controls_clamp.margin_end = 16;
            _controls_clamp.margin_bottom = 16;
            overlay_box.append (_controls_clamp);

            _seek = new SeekBar ();
            seek_slot.append (_seek);
            _seek.seek.connect (_on_scrub);
            _seek.notify["dragging"].connect (() => _poke ());

            remaining_btn.clicked.connect (() => {
                _show_remaining = !_show_remaining;
                remaining_btn.tooltip_text = _show_remaining ? _("Show Total Time") : _("Show Remaining Time");
                _update_position ();
            });

            _build_volume_popover ();
            _build_speed_menu ();
            tracks_btn.direction = Gtk.ArrowType.UP;
            tracks_btn.menu_model = new GLib.Menu ();
            tracks_btn.popover.add_css_class ("singularity-app-menu");
            foreach (var btn in new Gtk.MenuButton[] { volume_btn, tracks_btn, speed_btn }) {
                btn.notify["active"].connect (() => _poke ());
            }

            var controls_motion = new Gtk.EventControllerMotion ();
            controls_motion.enter.connect (() => _pointer_on_controls = true);
            controls_motion.leave.connect (() => {
                _pointer_on_controls = false;
                _poke ();
            });
            _controls_clamp.add_controller (controls_motion);

            var click = new Gtk.GestureClick ();
            click.pressed.connect ((n, x, y) => _on_video_click (click, n, x, y));
            overlay_box.add_controller (click);

            return player_overlay;
        }

        private void _build_volume_popover () {
            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            box.add_css_class ("videos-volume");

            var mute = new Gtk.ToggleButton ();
            mute.icon_name = "audio-volume-muted-symbolic";
            mute.tooltip_text = _("Mute");
            mute.action_name = "win.mute";
            box.append (mute);

            _volume_scale = new Gtk.Scale.with_range (Gtk.Orientation.HORIZONTAL, 0, 100, 1);
            _volume_scale.draw_value = false;
            _volume_scale.hexpand = true;
            _volume_scale.update_property (Gtk.AccessibleProperty.LABEL, _("Volume"), -1);
            _volume_scale.value_changed.connect (() => {
                if (_syncing_volume) return;
                _set_volume (_volume_scale.get_value () / 100.0);
            });
            box.append (_volume_scale);

            _volume_value = new Gtk.Label ("100%");
            _volume_value.add_css_class ("videos-volume-value");
            _volume_value.xalign = 1;
            box.append (_volume_value);

            var popover = new Gtk.Popover ();
            popover.child = box;
            volume_btn.popover = popover;
            volume_btn.direction = Gtk.ArrowType.UP;

            var scroll = new Gtk.EventControllerScroll (Gtk.EventControllerScrollFlags.VERTICAL);
            scroll.scroll.connect ((dx, dy) => {
                _set_volume (_player.volume - dy * 0.05);
                return true;
            });
            volume_btn.add_controller (scroll);
        }

        private void _build_speed_menu () {
            _speed_label = new Gtk.Label (_rate_label (1.0));
            speed_btn.child = _speed_label;
            speed_btn.direction = Gtk.ArrowType.UP;
            var menu = new GLib.Menu ();
            foreach (double r in RATES) {
                var item = new GLib.MenuItem (r == 1.0 ? _("Normal") : _rate_label (r), null);
                item.set_action_and_target_value ("win.rate", new GLib.Variant.double (r));
                menu.append_item (item);
            }
            speed_btn.menu_model = menu;
            speed_btn.popover.add_css_class ("singularity-app-menu");
        }

        private static string _rate_label (double rate) {
            return "%g×".printf (rate);
        }

        private void _connect_signals () {
            var motion = new Gtk.EventControllerMotion ();
            motion.enter.connect ((x, y) => {
                _last_x = x;
                _last_y = y;
                _poke ();
            });
            motion.motion.connect ((x, y) => {
                if (Math.fabs (x - _last_x) < 1 && Math.fabs (y - _last_y) < 1) return;
                _last_x = x;
                _last_y = y;
                _poke ();
            });
            ((Gtk.Widget) this).add_controller (motion);

            var keys = new Gtk.EventControllerKey ();
            keys.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            keys.key_pressed.connect (_on_key);
            ((Gtk.Widget) this).add_controller (keys);

            var paste = new Gtk.EventControllerKey ();
            paste.propagation_phase = Gtk.PropagationPhase.BUBBLE;
            paste.key_pressed.connect ((keyval, keycode, state) => {
                if ((keyval == Gdk.Key.v || keyval == Gdk.Key.V) && (state & Gdk.ModifierType.CONTROL_MASK) != 0 && !_on_trim ()) {
                    if (get_focus () is Gtk.Editable) return false;
                    _paste_address ();
                    return true;
                }
                return false;
            });
            ((Gtk.Widget) this).add_controller (paste);

            _stack.notify["visible-child-name"].connect (() => {
                _update_media_actions ();
                _sync_trim_bubbles ();
                bool player = _on_player ();
                set_bubbles_on_hover (player);
                if (!player) _cancel_hide ();
                _poke ();
            });

            _pos_timer_id = GLib.Timeout.add (250, () => {
                _update_position ();
                _ticks++;
                if (_is_playing && _ticks % 20 == 0) _save_position ();
                if (_ticks % 4 == 0) _mpris.update ();
                return GLib.Source.CONTINUE;
            });

            close_request.connect (() => {
                _save_position ();
                _mpris.stop ();
                if (_resume_id != 0) { GLib.Source.remove (_resume_id); _resume_id = 0; }
                if (_pos_timer_id != 0) { GLib.Source.remove (_pos_timer_id); _pos_timer_id = 0; }
                if (_click_timer_id != 0) { GLib.Source.remove (_click_timer_id); _click_timer_id = 0; }
                _cancel_hide ();
                if (_trim != null) _trim.shutdown ();
                _library.shutdown ();
                return false;
            });
        }

        private bool _on_trim () {
            return _stack != null && _stack.visible_child_name == "trim";
        }

        private void _show_page (string name) {
            if (name != "embed" && _stack.visible_child_name == "embed") _library.leave_embed ();
            if (name != "player" && _on_player () && _is_playing) _toggle_play ();
            _stack.set_visible_child_name (name);
        }

        private bool _on_embed () {
            return _stack != null && _stack.visible_child_name == "embed";
        }

        private bool _sidebar_page () {
            string n = _stack != null ? _stack.visible_child_name : "";
            return n == "welcome" || n == "browse";
        }

        private void _toggle_sidebar () {
            if (_on_trim ()) return;
            bool show = !get_sidebar_visible ();
            if (_sidebar_page ()) _sidebar_wanted = show;
            set_sidebar_visible (show);
        }

        private void _back_to_library () {
            if (_on_embed ()) {
                _leave_embed ();
                return;
            }
            if (_on_player ()) {
                _save_position ();
                _show_page (_library.browse.current != null ? "browse" : "welcome");
            }
        }

        private void _leave_embed () {
            _library.leave_embed ();
            _stack.set_visible_child_name (_library.browse.current != null ? "browse" : "welcome");
        }

        private void _sync_trim_bubbles () {
            bool trim = _on_trim ();
            bool embed = _on_embed ();
            _sidebar_btn.visible = _sidebar_page ();
            _embed_back_btn.visible = embed || _on_player ();
            _browser_btn.visible = embed;
            if (_sidebar_page ()) set_sidebar_visible (_sidebar_wanted);
            else if (get_sidebar_visible () && (trim || embed || _stack.visible_child_name == "player")) set_sidebar_visible (false);
            _trim_done_btn.visible = trim;
            _trim_export_btn.visible = trim;
            _open_btn.visible = !trim && !embed && !_sidebar_page ();
            _trim_btn.visible = _on_player () && _uri.has_prefix ("file://");
            _share_btn.visible = _on_player () && _uri != "";
        }

        private TrimView _ensure_trim () {
            if (_trim == null) {
                _trim = new TrimView ();
                _trim.load_failed.connect ((msg) => add_toast (new Singularity.Widgets.Toast (msg)));
                _stack.add_named (_trim, "trim");
            }
            return _trim;
        }

        public void enter_trim () {
            if (_uri == "" || !_on_player ()) {
                _pick_for_trim ();
                return;
            }
            _start_trim (GLib.File.new_for_uri (_uri));
        }

        private void _start_trim (GLib.File file) {
            if (_is_playing) _toggle_play ();
            var view = _ensure_trim ();
            view.open_file (file);
            title = _("Trim");
            if (!fullscreened && !maximized && (get_width () < 1100 || get_height () < 740))
                set_default_size (int.max (get_width (), 1100), int.max (get_height (), 740));
            _stack.set_visible_child_name ("trim");
            view.grab_focus ();
        }

        private void _pick_for_trim () {
            _open_dialog = new Gtk.FileChooserNative (
                _("Choose a Video to Trim"), this,
                Gtk.FileChooserAction.OPEN, _("Trim"), _("Cancel"));
            var filter = new Gtk.FileFilter ();
            filter.add_mime_type ("video/*");
            filter.add_mime_type ("audio/*");
            filter.name = _("Media Files");
            _open_dialog.add_filter (filter);
            _open_dialog.response.connect ((id) => {
                var picked = _open_dialog.get_file ();
                if (id == Gtk.ResponseType.ACCEPT && picked != null) _start_trim (picked);
                _open_dialog = null;
            });
            _open_dialog.show ();
        }

        private void _close_trim () {
            if (_trim == null || !_trim.modified) {
                leave_trim ();
                return;
            }
            _trim.stop ();
            var dlg = new Singularity.Widgets.ConfirmDialog ((Gtk.Application) application,
                _("Discard Trim Edits?"), null,
                _("The cuts, crop and clip changes have not been exported."),
                _("Discard"), Singularity.Widgets.ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.transient_for = this;
            dlg.response.connect ((r) => {
                if (r == Singularity.Widgets.ConfirmDialog.Response.PRIMARY) leave_trim ();
            });
            dlg.present ();
        }

        public void leave_trim () {
            if (_trim != null) _trim.stop ();
            title = _("Videos");
            _stack.set_visible_child_name (_uri != "" ? "player" : "welcome");
        }

        private void _export_trim () {
            if (_trim == null || !_trim.has_media) return;
            _trim.stop ();
            string name = _trim.edl.get_clip (0).display_name ();
            var dialog = new ExportDialog ((Gtk.Application) application, this, _trim.edl, name);
            dialog.exported.connect ((path) => {
                _trim.modified = false;
                var toast = new Singularity.Widgets.Toast (_("Saved %s").printf (GLib.Path.get_basename (path)));
                toast.button_label = _("Play");
                toast.button_clicked.connect (() => {
                    leave_trim ();
                    _play_file (GLib.File.new_for_path (path));
                });
                add_toast (toast);
            });
            dialog.open_dialog ();
        }

        public void open_trim_files (GLib.File[] files) {
            if (files.length == 0) return;
            _start_trim (files[0]);
            for (int i = 1; i < files.length; i++) _trim.add_file (files[i]);
        }

        private bool _on_player () {
            return _stack != null && _stack.visible_child_name == "player";
        }

        private bool _on_key (uint keyval, uint keycode, Gdk.ModifierType state) {
            if (_stack.visible_child_name == "browse" && keyval == Gdk.Key.Left && (state & Gdk.ModifierType.ALT_MASK) != 0) {
                _library.browse.go_back ();
                return true;
            }
            if (!_on_player ()) return false;
            _poke ();
            var mods = Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK | Gdk.ModifierType.SUPER_MASK;
            if ((state & mods) != 0) return false;
            switch (keyval) {
                case Gdk.Key.space:
                case Gdk.Key.KP_Space:
                    _toggle_play ();
                    return true;
                case Gdk.Key.Left:
                    _skip (-SKIP_NS);
                    return true;
                case Gdk.Key.Right:
                    _skip (SKIP_NS);
                    return true;
                case Gdk.Key.Up:
                    _set_volume (_player.volume + 0.05);
                    return true;
                case Gdk.Key.Down:
                    _set_volume (_player.volume - 0.05);
                    return true;
                case Gdk.Key.f:
                case Gdk.Key.F:
                    _toggle_fullscreen ();
                    return true;
                case Gdk.Key.m:
                case Gdk.Key.M:
                    _toggle_mute ();
                    return true;
                case Gdk.Key.Escape:
                    if (!fullscreened) return false;
                    unfullscreen ();
                    return true;
                default:
                    return false;
            }
        }

        private void _on_video_click (Gtk.GestureClick click, int n_press, double x, double y) {
            var target = overlay_box.pick (x, y, Gtk.PickFlags.DEFAULT);
            if (target != null && (target == _controls_clamp || target.is_ancestor (_controls_clamp))) return;
            if (_click_timer_id != 0) {
                GLib.Source.remove (_click_timer_id);
                _click_timer_id = 0;
            }
            if (n_press == 2) {
                _toggle_fullscreen ();
                return;
            }
            if (n_press != 1) return;
            var device = click.get_current_event_device ();
            bool touch = device != null && device.source == Gdk.InputSource.TOUCHSCREEN;
            _click_timer_id = GLib.Timeout.add (250, () => {
                _click_timer_id = 0;
                if (!touch) {
                    _toggle_play ();
                } else if (_chrome_visible && _is_playing) {
                    _cancel_hide ();
                    _set_chrome_visible (false);
                } else {
                    _poke ();
                }
                return GLib.Source.REMOVE;
            });
        }

        private void _on_scrub (double fraction, bool final) {
            int64 dur = _player.duration_ns ();
            if (dur <= 0) return;
            int64 target = (int64) (fraction * dur);
            elapsed_lbl.label = SeekBar.format_time (target);
            int64 now = GLib.get_monotonic_time ();
            if (!final && now - _last_scrub < 60000) return;
            _last_scrub = now;
            _player.seek_ns_fast (target, !final);
            if (final) {
                _mpris.seeked (target);
                _update_position ();
            }
        }

        private void _on_error (string message) {
            warning ("GstPlayer error: %s", message);
            if (_uri == "" || !_on_player ()) return;
            _player.pause ();
            _is_playing = false;
            _update_play_icon ();
            _error_page.description = message;
            _stack.set_visible_child_name ("error");
            _mpris.update ();
        }

        public void open_file (GLib.File f) {
            _play_file (f);
        }

        public void open_address_dialog () {
            var dlg = new Singularity.Widgets.ConfirmDialog ((Gtk.Application) application, _("Open Address"), null,
                _("Paste a link to a YouTube or PeerTube video, or to a video file."), _("Open"),
                Singularity.Widgets.ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = this;
            var group = new Singularity.Widgets.PreferencesGroup ();
            var entry = new Singularity.Widgets.EntryRow (_("Address"));
            group.add_row (entry);
            dlg.custom_area.append (group);
            dlg.primary_sensitive = false;
            entry.entry_changed.connect (() => dlg.primary_sensitive = VideoLibrary.normalize_address (entry.text) != null);
            entry.entry_activated.connect (() => {
                if (VideoLibrary.normalize_address (entry.text) == null) return;
                dlg.response (Singularity.Widgets.ConfirmDialog.Response.PRIMARY);
                dlg.close_dialog ();
            });
            dlg.response.connect ((r) => {
                if (r == Singularity.Widgets.ConfirmDialog.Response.PRIMARY) _library.open_address.begin (entry.text);
            });
            get_clipboard ().read_text_async.begin (null, (o, res) => {
                try {
                    string? text = get_clipboard ().read_text_async.end (res);
                    if (text != null && VideoLibrary.normalize_address (text) != null && entry.text == "") {
                        entry.text = text.strip ();
                        dlg.primary_sensitive = true;
                    }
                } catch (GLib.Error e) {
                }
            });
            dlg.present ();
            entry.grab_focus ();
        }

        private void _paste_address () {
            get_clipboard ().read_text_async.begin (null, (o, res) => {
                try {
                    string? text = get_clipboard ().read_text_async.end (res);
                    if (text != null && VideoLibrary.normalize_address (text) != null) _library.open_address.begin (text);
                } catch (GLib.Error e) {
                }
            });
        }

        public void open_file_dialog () {
            _open_dialog = new Gtk.FileChooserNative (
                _("Open Video"), this,
                Gtk.FileChooserAction.OPEN, _("Open"), _("Cancel"));
            var filter = new Gtk.FileFilter ();
            filter.add_mime_type ("video/*");
            filter.add_mime_type ("audio/*");
            filter.name = _("Media Files");
            _open_dialog.add_filter (filter);
            _open_dialog.response.connect ((id) => {
                var picked = _open_dialog.get_file ();
                if (id == Gtk.ResponseType.ACCEPT && picked != null)
                    _play_file (picked);
                _open_dialog = null;
            });
            _open_dialog.show ();
        }

        private void _record (int64 pos, int64 dur) {
            if (_stream_item != null)
                _history.record_item (_uri, pos, dur, _stream_item.title, _stream_item.source_id, _stream_item.id, _stream_item.image_url);
            else
                _history.record (_uri, pos, dur);
        }

        private void _save_position () {
            if (_uri == "" || !_on_player ()) return;
            int64 pos = _player.position_ns ();
            int64 dur = _player.duration_ns ();
            if (dur > 0 && pos >= dur - 15000000000) pos = 0;
            _record (pos, dur);
        }

        private void _resume (int64 position) {
            if (_resume_id != 0) GLib.Source.remove (_resume_id);
            int attempts = 0;
            _resume_id = GLib.Timeout.add (100, () => {
                if (_player.duration_ns () > 0) {
                    _player.seek_ns (position);
                    _update_position ();
                    _mpris.seeked (position);
                    _resume_id = 0;
                    return GLib.Source.REMOVE;
                }
                if (++attempts > 50) {
                    _resume_id = 0;
                    return GLib.Source.REMOVE;
                }
                return GLib.Source.CONTINUE;
            });
        }

        public bool mpris_playing { get { return _on_embed () ? _library.embed.playing : _is_playing; } }
        public bool mpris_loaded { get { return (_on_player () && _uri != "") || (_on_embed () && _library.embed.player != null); } }
        public string mpris_uri {
            owned get {
                if (_on_embed () && _library.embed.item != null) return _library.embed.external_uri;
                return _stream_item != null && _stream_item.external_url != "" ? _stream_item.external_url : _uri;
            }
        }
        public string mpris_title {
            owned get {
                if (_on_embed () && _library.embed.item != null) return _library.embed.item.title;
                return _stream_item != null ? _stream_item.title : "";
            }
        }
        public int64 mpris_position { get { return _on_embed () && _library.embed.player != null ? _library.embed.player.position_ms * 1000000 : _player.position_ns (); } }
        public int64 mpris_duration { get { return _on_embed () && _library.embed.player != null ? _library.embed.player.duration_ms * 1000000 : _player.duration_ns (); } }

        public void mpris_set_playing (bool playing) {
            if (!mpris_loaded) return;
            if (_on_embed ()) {
                var p = _library.embed.player;
                if (p == null) return;
                if (playing) p.play (); else p.pause ();
                return;
            }
            if (playing == _is_playing) return;
            _toggle_play ();
        }

        public void mpris_stop () {
            if (_on_embed ()) {
                var p = _library.embed.player;
                if (p != null) p.pause ();
                return;
            }
            _stop ();
        }

        public void mpris_seek_to (int64 position) {
            if (_on_embed ()) {
                var p = _library.embed.player;
                if (p != null) p.seek (position / 1000000);
                return;
            }
            _player.seek_ns (position);
            _update_position ();
        }

        public void mpris_raise () {
            present ();
        }

        public void mpris_open (string uri) {
            _play_file (GLib.File.new_for_uri (uri));
        }

        public void resume_last () {
            var recent = _history.recent (5);
            HistoryEntry? pick = recent.length > 0 ? recent[0] : null;
            foreach (var e in recent) {
                if (e.resumable) { pick = e; break; }
            }
            if (pick != null) _play_file (GLib.File.new_for_uri (pick.uri));
            else open_file_dialog ();
        }

        private void _add_moment (string target, string title, int seconds, string? note_id) {
            string when = seconds >= 3600 ? "%d:%02d:%02d".printf (seconds / 3600, (seconds / 60) % 60, seconds % 60) : "%d:%02d".printf (seconds / 60, seconds % 60);
            string link = "sinty-videos://moment?uri=%s&t=%d".printf (GLib.Uri.escape_string (target, null, false), seconds);
            try {
                var note = Singularity.Notes.NotePicker.target (note_id, title);
                Singularity.Notes.NotePicker.append (note, "[%s, %s](%s)\n".printf (title.replace ("]", ""), when, link));
                add_toast (Singularity.Notes.NotePicker.toast (note, note_id == null, _("Moment")));
            } catch (GLib.Error e) {
                warning ("Videos: add moment failed: %s", e.message);
            }
        }

        private void _play_file (GLib.File file) {
            string uri = file.get_uri ();
            if (uri.has_prefix ("sinty-videos://")) {
                try {
                    var parsed = GLib.Uri.parse (uri, GLib.UriFlags.NONE);
                    var q = GLib.Uri.parse_params (parsed.get_query () ?? "", -1, "&", GLib.UriParamsFlags.NONE);
                    string? target = q["uri"];
                    if (target != null && target != "") _play_stream (target, null, null, int64.parse (q["t"] ?? "0") * 1000000000);
                } catch (GLib.Error e) {
                    warning ("Videos: bad moment link %s", uri);
                }
                return;
            }
            if (uri.has_prefix ("videos-source:")) {
                if (!_library.open_history_key (uri)) open_file_dialog ();
                return;
            }
            _play_stream (uri, null, null, -1);
        }

        private void _play_stream (string uri, GLib.HashTable<string, string>? headers, Singularity.MediaSources.MediaItem? item, int64 start_ns) {
            if (_uri != "") _save_position ();
            if (_on_embed ()) _library.leave_embed ();
            _stream_item = item != null && item.source_id != LocalVideosSource.ID ? item : null;
            _stream_uri = uri;
            _uri = _stream_item != null ? VideoHistory.remote_key (item.source_id, item.id) : uri;
            _player.set_http_headers (headers);
            _player.open (uri);
            _tracks_sig = "";
            tracks_btn.visible = false;
            _rate_action.set_state (new GLib.Variant.double (1.0));
            _speed_label.label = _rate_label (1.0);
            _seek.fraction = 0;
            _seek.buffered = -1;
            var entry = _history.find (_uri);
            if (start_ns >= 0) _resume (start_ns);
            else if (entry != null && entry.resumable) _resume (entry.position);
            _record (entry != null && entry.resumable ? entry.position : 0, entry != null ? entry.duration : 0);
            _is_playing = true;
            _update_play_icon ();
            _stack.set_visible_child_name ("player");
            _poke ();
        }

        private bool _frame_geometry (out double ox, out double oy, out double scale) {
            ox = oy = 0;
            scale = 1;
            var paintable = video_picture.paintable;
            if (paintable == null || _live_text == null) return false;
            Graphene.Rect bounds;
            if (!video_picture.compute_bounds (_live_text.view, out bounds)) return false;
            double w = paintable.get_intrinsic_width (), h = paintable.get_intrinsic_height ();
            if (w <= 0 || h <= 0) return false;
            scale = double.min (bounds.size.width / w, bounds.size.height / h);
            ox = bounds.origin.x + (bounds.size.width - w * scale) / 2;
            oy = bounds.origin.y + (bounds.size.height - h * scale) / 2;
            return true;
        }

        private void _sync_live_text () {
            if (_live_text == null) return;
            if (_is_playing) {
                _live_text.active = false;
                _live_text.toggle.visible = false;
                _live_text.set_texture (null);
                return;
            }
            var paintable = video_picture.paintable;
            var native = video_picture.get_native ();
            if (paintable == null || native == null) return;
            int w = paintable.get_intrinsic_width (), h = paintable.get_intrinsic_height ();
            if (w <= 0 || h <= 0) return;
            var snap = new Gtk.Snapshot ();
            paintable.snapshot (snap, w, h);
            var node = snap.to_node ();
            if (node == null) return;
            _live_text.set_texture (native.get_renderer ().render_texture (node, null));
            _live_text.toggle.visible = true;
        }

        private void _toggle_play () {
            if (_is_playing) {
                _player.pause ();
                _is_playing = false;
            } else {
                int64 dur = _player.duration_ns ();
                if (dur > 0 && _player.position_ns () >= dur - 500000000) _player.seek_ns (0);
                _player.play ();
                _is_playing = true;
            }
            _update_play_icon ();
            _poke ();
            _save_position ();
            _mpris.update ();
            _sync_live_text ();
        }

        private void _stop () {
            _player.pause ();
            _player.seek_to (0);
            _is_playing = false;
            _update_play_icon ();
            _update_position ();
            _poke ();
            _mpris.update ();
        }

        private void _toggle_mute () {
            _player.muted = !_player.muted;
            _sync_volume ();
        }

        private void _toggle_fullscreen () {
            if (fullscreened) unfullscreen (); else fullscreen ();
        }

        private void _skip (int64 ns) {
            _player.skip (ns);
            _update_position ();
        }

        private void _set_rate (double rate) {
            _player.rate = rate;
            _rate_action.set_state (new GLib.Variant.double (_player.rate));
            _speed_label.label = _rate_label (_player.rate);
        }

        private void _set_volume (double volume) {
            double v = volume.clamp (0.0, 1.0);
            _player.volume = v;
            if (v > 0 && _player.muted) _player.muted = false;
            _sync_volume ();
        }

        private void _sync_volume () {
            double v = _player.volume;
            bool muted = _player.muted;
            _syncing_volume = true;
            _volume_scale.set_value (Math.round (v * 100));
            _syncing_volume = false;
            _volume_value.label = "%d%%".printf ((int) Math.round (v * 100));
            _mute_action.set_state (new GLib.Variant.boolean (muted));
            string icon;
            if (muted || v <= 0) icon = "audio-volume-muted-symbolic";
            else if (v < 0.34) icon = "audio-volume-low-symbolic";
            else if (v < 0.67) icon = "audio-volume-medium-symbolic";
            else icon = "audio-volume-high-symbolic";
            volume_btn.icon_name = icon;
            volume_btn.tooltip_text = muted ? _("Volume (Muted)") : _("Volume");
        }

        private void _rebuild_tracks () {
            var subs = _player.subtitle_tracks ();
            var audio = _player.audio_tracks ();
            string sig = string.joinv ("\n", subs) + "\t" + string.joinv ("\n", audio);
            if (sig != _tracks_sig) {
                _tracks_sig = sig;
                var menu = new GLib.Menu ();
                if (subs.length > 0) {
                    var section = new GLib.Menu ();
                    var off = new GLib.MenuItem (_("Off"), null);
                    off.set_action_and_target_value ("win.subtitle", new GLib.Variant.int32 (-1));
                    section.append_item (off);
                    for (int i = 0; i < subs.length; i++) {
                        var item = new GLib.MenuItem (subs[i], null);
                        item.set_action_and_target_value ("win.subtitle", new GLib.Variant.int32 (i));
                        section.append_item (item);
                    }
                    menu.append_section (_("Subtitles"), section);
                }
                if (audio.length > 1) {
                    var section = new GLib.Menu ();
                    for (int i = 0; i < audio.length; i++) {
                        var item = new GLib.MenuItem (audio[i], null);
                        item.set_action_and_target_value ("win.audio-track", new GLib.Variant.int32 (i));
                        section.append_item (item);
                    }
                    menu.append_section (_("Audio"), section);
                }
                ((Gtk.PopoverMenu) tracks_btn.popover).menu_model = menu;
                tracks_btn.visible = subs.length > 0 || audio.length > 1;
            }
            _subtitle_action.set_state (new GLib.Variant.int32 (_player.current_subtitle));
            _audio_action.set_state (new GLib.Variant.int32 (_player.current_audio));
        }

        private void _update_play_icon () {
            play_btn.icon_name = _is_playing
                ? "media-playback-pause-symbolic"
                : "media-playback-start-symbolic";
            play_btn.tooltip_text = _is_playing ? _("Pause") : _("Play");
        }

        private void _update_position () {
            if (_seek == null) return;
            int64 dur = _player.duration_ns ();
            int64 pos = _player.position_ns ();
            _seek.duration = dur;
            if (!_seek.dragging) {
                _seek.fraction = dur > 0 ? ((double) pos / dur).clamp (0, 1) : 0;
                elapsed_lbl.label = SeekBar.format_time (pos);
            }
            _seek.buffered = _player.buffered_fraction ();
            if (_show_remaining && dur > 0)
                remaining_btn.label = "-" + SeekBar.format_time (dur - pos);
            else
                remaining_btn.label = SeekBar.format_time (dur);
        }

        private void _poke () {
            _set_chrome_visible (true);
            _schedule_hide ();
        }

        private void _cancel_hide () {
            if (_hide_timer_id != 0) {
                GLib.Source.remove (_hide_timer_id);
                _hide_timer_id = 0;
            }
        }

        private void _schedule_hide () {
            _cancel_hide ();
            if (!_is_playing || !_on_player ()) return;
            _hide_timer_id = GLib.Timeout.add (HIDE_DELAY_MS, () => {
                _hide_timer_id = 0;
                if (_can_hide ()) _set_chrome_visible (false);
                return GLib.Source.REMOVE;
            });
        }

        private bool _can_hide () {
            return _on_player () && _is_playing && !_pointer_on_controls
                && !_seek.dragging && !_has_open_popover (this);
        }

        private static bool _has_open_popover (Gtk.Widget root) {
            for (var child = root.get_first_child (); child != null; child = child.get_next_sibling ()) {
                if (child is Gtk.Popover && child.visible)
                    return true;
                if (_has_open_popover (child)) return true;
            }
            return false;
        }

        private void _set_chrome_visible (bool visible) {
            if (_controls_clamp == null || visible == _chrome_visible) return;
            _chrome_visible = visible;
            _controls_clamp.can_target = visible;
            if (_bubble_row != null) _bubble_row.can_target = visible;
            set_cursor_from_name (visible ? null : "none");
            if (_fade != null) {
                _fade.reset ();
                _fade = null;
            }
            double to = visible ? 1.0 : 0.0;
            if (!get_settings ().gtk_enable_animations || !_controls_clamp.get_mapped ()) {
                _apply_chrome_opacity (to);
                return;
            }
            var anim = new Singularity.Animation.TimedAnimation (
                _controls_clamp, _controls_clamp.opacity, to, visible ? 160 : 320);
            anim.tick.connect (() => _apply_chrome_opacity (anim.value));
            anim.done.connect (() => _apply_chrome_opacity (to));
            _fade = anim;
            anim.play ();
        }

        private void _apply_chrome_opacity (double opacity) {
            _controls_clamp.opacity = opacity;
            if (_bubble_row != null) _bubble_row.opacity = opacity;
        }

        private void _auto_resize () {
            if (!_is_playing || _player.paintable == null) return;
            double w = _player.paintable.get_intrinsic_width ();
            double h = _player.paintable.get_intrinsic_height ();
            if (w <= 0 || h <= 0) return;

            var display  = Gdk.Display.get_default ();
            var surface  = get_surface ();
            Gdk.Monitor? mon = null;
            if (surface != null)
                mon = display.get_monitor_at_surface (surface);
            else if (display.get_monitors ().get_n_items () > 0)
                mon = display.get_monitors ().get_item (0) as Gdk.Monitor;

            double max_w = 1920, max_h = 1080;
            if (mon != null) {
                var geo = mon.get_geometry ();
                max_w = geo.width  * 0.9;
                max_h = geo.height * 0.9;
            }
            double scale = Math.fmin (max_w / w, max_h / h);
            if (scale < 1.0) { w *= scale; h *= scale; }

            if (Math.fabs (get_width () - w) > 10 || Math.fabs (get_height () - h) > 10)
                set_default_size ((int) w, (int) h);
        }
    }
}
