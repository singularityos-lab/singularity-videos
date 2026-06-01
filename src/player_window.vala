using Gtk;
using Gdk;
using Gst;

namespace Singularity.Apps.Videos {

    [GtkTemplate(ui = "/dev/sinty/videos/ui/player.ui")]
    public class PlayerWindow : Singularity.Widgets.Window {

        [GtkChild] unowned Gtk.Overlay  player_overlay;
        [GtkChild] unowned Gtk.Picture  video_picture;
        [GtkChild] unowned Gtk.Box      controls_box;
        [GtkChild] unowned Gtk.Scale    seek_bar;
        [GtkChild] unowned Gtk.Button   play_btn;
        [GtkChild] unowned Gtk.Button   back_btn;
        [GtkChild] unowned Gtk.Button   fwd_btn;
        [GtkChild] unowned Gtk.Box      click_spacer;

        private Gtk.Stack        _stack;

        private GstPlayer        _player;

        private bool             _controls_visible = true;
        private bool             _is_playing       = false;
        private bool             _is_seeking       = false;
        private uint             _hide_timer_id    = 0;
        private uint             _pos_timer_id     = 0;
        // Held strong reference to keep the FileChooserNative alive while the
        // portal is round-tripping. Local-var-only refs get unref'd by Vala
        // when open_file_dialog() returns, freeing the dialog BEFORE the
        // portal can fire `response` - symptom: picker opens, user picks
        // a file, nothing happens (and the video appears to open in a new
        // window because xdg-open kicks in via the default handler).
        private Gtk.FileChooserNative? _open_dialog = null;

        public PlayerWindow (Gtk.Application app) {
            GLib.Object(application: app);
            default_width  = 960;
            default_height = 540;
            title          = "Videos";

            _player = new GstPlayer ();
            _player.error_occurred.connect ((msg) => {
                warning ("GstPlayer error: %s", msg);
            });

            _build_ui ();
            _connect_signals ();
        }

        private void _build_ui () {
            // Drag + open + close live in the Window's bubble bar so
            // they're available in both welcome and player states.
            add_bubble_icon ("document-open-symbolic", "Open Video",
                             () => open_file_dialog ());
            add_bubble_icon ("window-close-symbolic", "Close",
                             () => close ());

            _stack = new Gtk.Stack ();
            _stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
            _stack.hexpand = true;
            _stack.vexpand = true;

            _stack.add_named (_build_welcome_page (), "welcome");
            _stack.add_named (_build_player_page (), "player");

            set_content (_stack);

            // Welcome is the initial state: bubbles always visible.
            set_bubbles_on_hover (false);
        }

        private Gtk.Widget _build_welcome_page () {
            var wp = new Singularity.Widgets.WelcomePage ();
            wp.app_icon_name = "dev.sinty.videos";
            wp.title         = _("Videos");
            // If the GTK4 paintable sink isn't available the video would
            // render to a separate floating Wayland surface - make the
            // missing dependency obvious to the user rather than silently
            // failing.
            if (_player.paintable == null) {
                wp.subtitle = _("Missing video sink. Install gstreamer1.0-gtk4 and restart.");
            } else {
                wp.subtitle = _("Watch movies, shows, and clips");
            }
            wp.add_action (
                "document-open-symbolic",
                "Open Video",
                "Open a video or audio file from your device",
                () => open_file_dialog ()
            );
            return wp;
        }

        private Gtk.Widget _build_player_page () {
            if (_player.paintable != null) {
                video_picture.set_paintable (_player.paintable);
                _player.paintable.invalidate_size.connect (() => _auto_resize ());
            }

            seek_bar.set_increments (1, 10);
            seek_bar.change_value.connect (_on_seek);

            back_btn.clicked.connect (() => _player.skip (-10000000000));
            play_btn.clicked.connect (_toggle_play);
            fwd_btn.clicked.connect (() => _player.skip (10000000000));

            var click = new Gtk.GestureClick ();
            click.pressed.connect (() => _toggle_controls ());
            click_spacer.add_controller (click);

            // Drag/open/close are now on the Window bubble bar
            // (handled in _build_ui). Player page just returns its
            // overlay; transport controls (seek/play/back/fwd) stay
            // baked into the player UI template.
            return player_overlay;
        }

        private void _connect_signals () {
            var motion = new Gtk.EventControllerMotion ();
            motion.motion.connect ((x, y) => {
                _show_controls ();
                _reset_hide_timer ();
            });
            _stack.add_controller (motion);

            _pos_timer_id = GLib.Timeout.add (1000, () => {
                if (_is_playing && !_is_seeking)
                    seek_bar.set_value (_player.position_percent ());
                return GLib.Source.CONTINUE;
            });

            close_request.connect (() => {
                if (_pos_timer_id  != 0) { GLib.Source.remove (_pos_timer_id);  _pos_timer_id  = 0; }
                if (_hide_timer_id != 0) { GLib.Source.remove (_hide_timer_id); _hide_timer_id = 0; }
                return false;
            });
        }

        public void open_file (GLib.File f) {
            _play_file (f);
        }

        public void open_file_dialog () {
            _open_dialog = new Gtk.FileChooserNative (
                "Open Video", this,
                Gtk.FileChooserAction.OPEN, "Open", "Cancel");
            var filter = new Gtk.FileFilter ();
            filter.add_mime_type ("video/*");
            filter.add_mime_type ("audio/*");
            filter.name = "Media Files";
            _open_dialog.add_filter (filter);
            _open_dialog.response.connect ((id) => {
                var picked = _open_dialog.get_file ();
                if (id == Gtk.ResponseType.ACCEPT && picked != null)
                    _play_file (picked);
                _open_dialog = null;  // release once response is delivered
            });
            _open_dialog.show ();
        }

        private void _play_file (GLib.File file) {
            _player.open (file.get_uri ());
            _is_playing = true;
            _update_play_icon ();
            _stack.set_visible_child_name ("player");
            // Bubbles fade out over the video and reappear on hover.
            set_bubbles_on_hover (true);
            _show_controls ();
            _reset_hide_timer ();
        }

        private void _toggle_play () {
            if (_is_playing) {
                _player.pause ();
                _is_playing = false;
            } else {
                _player.play ();
                _is_playing = true;
            }
            _update_play_icon ();
            _reset_hide_timer ();
        }

        private void _update_play_icon () {
            play_btn.icon_name = _is_playing
                ? "media-playback-pause-symbolic"
                : "media-playback-start-symbolic";
        }

        private bool _on_seek (Gtk.ScrollType scroll, double value) {
            _is_seeking = true;
            _player.seek_to (value);
            _is_seeking = false;
            return false;
        }

        private void _toggle_controls () {
            if (_controls_visible) _hide_controls (); else _show_controls ();
        }

        private void _show_controls () {
            if (_controls_visible) return;
            _controls_visible    = true;
            controls_box.opacity = 1.0;
        }

        private void _hide_controls () {
            if (!_controls_visible) return;
            _controls_visible    = false;
            controls_box.opacity = 0.0;
        }

        private void _reset_hide_timer () {
            if (_hide_timer_id != 0) GLib.Source.remove (_hide_timer_id);
            _hide_timer_id = GLib.Timeout.add_seconds (3, () => {
                if (_is_playing) _hide_controls ();
                _hide_timer_id = 0;
                return GLib.Source.REMOVE;
            });
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
