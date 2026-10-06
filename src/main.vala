using Singularity.Apps.Videos;

int main (string[] args) {
    var app = new VideosApp ();
    return app.run (args);
}

namespace Singularity.Apps.Videos {

    public class VideosApp : Singularity.Application {

        private PlayerWindow? _player_window = null;
        private bool _trim_files = false;

        public VideosApp () {
            GLib.Object (application_id: "dev.sinty.videos",
                         flags: GLib.ApplicationFlags.HANDLES_OPEN);
            force_dark = true;
            add_main_option ("resume-last", 0, GLib.OptionFlags.NONE, GLib.OptionArg.NONE, _("Resume the last video"), null);
            add_main_option ("open-video", 0, GLib.OptionFlags.NONE, GLib.OptionArg.NONE, _("Choose a video to play"), null);
            add_main_option ("trim", 0, GLib.OptionFlags.NONE, GLib.OptionArg.NONE, _("Open the files in the trim editor"), null);
        }

        protected override int handle_local_options (GLib.VariantDict options) {
            string? action = null;
            if (options.contains ("trim")) _trim_files = true;
            if (options.contains ("resume-last")) action = "resume-last";
            else if (options.contains ("open-video")) action = "open-video";
            if (action == null) return -1;
            try {
                register (null);
            } catch (GLib.Error e) {
                warning ("videos: %s", e.message);
                return 1;
            }
            activate_action (action, null);
            return get_is_remote () ? 0 : -1;
        }

        protected override void startup () {
            base.startup ();

            var css = new Gtk.CssProvider ();
            css.load_from_resource ("/dev/sinty/videos/style.css");
            Gtk.IconTheme.get_for_display (Gdk.Display.get_default ()).add_resource_path ("/dev/sinty/videos/icons");
            Gtk.StyleContext.add_provider_for_display (Gdk.Display.get_default (), css,
                Gtk.STYLE_PROVIDER_PRIORITY_USER + 1);

            var file_menu = new GLib.Menu ();
            var file_open = new GLib.Menu ();
            file_open.append (_("Open Video…"), "app.open");
            file_open.append (_("Open Address…"), "win.open-address");
            file_menu.append_section (null, file_open);
            var file_share = new GLib.Menu ();
            file_share.append (_("Share…"), "win.share");
            file_menu.append_section (null, file_share);
            var file_close = new GLib.Menu ();
            file_close.append (_("Close Window"), "win.close");
            file_close.append (_("Quit"), "app.quit");
            file_menu.append_section (null, file_close);
            var menu = new GLib.Menu ();
            menu.append_submenu (_("File"), file_menu);
            var edit_menu = new GLib.Menu ();
            var edit_trim = new GLib.Menu ();
            edit_trim.append (_("Trim Video…"), "win.trim");
            edit_menu.append_section (null, edit_trim);
            var edit_settings = new GLib.Menu ();
            edit_settings.append (_("Settings"), "app.settings");
            edit_menu.append_section (null, edit_settings);
            menu.append_submenu (_("Edit"), edit_menu);
            var view_menu = new GLib.Menu ();
            view_menu.append (_("Fullscreen"), "win.fullscreen");
            menu.append_submenu (_("View"), view_menu);
            var playback_menu = new GLib.Menu ();
            var play_section = new GLib.Menu ();
            play_section.append (_("Play or Pause"), "win.play-pause");
            play_section.append (_("Stop"), "win.stop");
            playback_menu.append_section (null, play_section);
            var seek_section = new GLib.Menu ();
            seek_section.append (_("Skip Back 10 Seconds"), "win.skip-back");
            seek_section.append (_("Skip Forward 10 Seconds"), "win.skip-forward");
            playback_menu.append_section (null, seek_section);
            var volume_section = new GLib.Menu ();
            volume_section.append (_("Volume Up"), "win.volume-up");
            volume_section.append (_("Volume Down"), "win.volume-down");
            volume_section.append (_("Mute"), "win.mute");
            playback_menu.append_section (null, volume_section);
            menu.append_submenu (_("Playback"), playback_menu);
            set_menubar (menu);

            var act_settings = new GLib.SimpleAction ("settings", null);
            act_settings.activate.connect (() => {
                try {
                    Singularity.Shell.ShellService shell = GLib.Bus.get_proxy_sync (GLib.BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                    shell.open_app_settings ("dev.sinty.videos");
                } catch (GLib.Error e) {
                    warning ("Failed to open settings: %s", e.message);
                }
            });
            add_action (act_settings);
            set_accels_for_action ("app.settings", { "<Control>comma" });
            set_accels_for_action ("app.open", { "<Control>o" });
            set_accels_for_action ("win.trim", { "<Control>t" });
            set_accels_for_action ("win.sidebar", { "F9" });
            set_accels_for_action ("win.open-address", { "<Control>l" });
            set_accels_for_action ("win.search", { "<Control>f" });
            set_accels_for_action ("win.close", { "<Control>w" });
            set_accels_for_action ("win.fullscreen", { "F11" });
            set_accels_for_action ("win.play-pause", { "<Control>space" });
            set_accels_for_action ("win.stop", { "<Control>period" });
            set_accels_for_action ("win.skip-back", { "<Control><Shift>Left" });
            set_accels_for_action ("win.skip-forward", { "<Control><Shift>Right" });
            set_accels_for_action ("win.volume-up", { "<Control>Up" });
            set_accels_for_action ("win.volume-down", { "<Control>Down" });
            set_accels_for_action ("win.mute", { "<Control>m" });

            var act_open = new GLib.SimpleAction ("open", null);
            act_open.activate.connect (() => {
                if (_player_window != null) _player_window.open_file_dialog ();
            });
            add_action (act_open);

            var act_resume = new GLib.SimpleAction ("resume-last", null);
            act_resume.activate.connect (() => {
                activate ();
                _player_window.resume_last ();
            });
            add_action (act_resume);

            var act_open_video = new GLib.SimpleAction ("open-video", null);
            act_open_video.activate.connect (() => {
                activate ();
                _player_window.open_file_dialog ();
            });
            add_action (act_open_video);

            var act_quit = new GLib.SimpleAction ("quit", null);
            act_quit.activate.connect (() => quit ());
            add_action (act_quit);
        }

        protected override void activate () {
            string[] gst_args = {};
            unowned string[] ua = gst_args;
            Gst.init (ref ua);

            // Re-activation must NOT spawn a second window - GTK / the
            // portal can call `activate()` multiple times during a single
            // session (e.g. after FileChooserNative completes, or when the
            // user reactivates from the dock). Without this guard you end
            // up with the original window still on the welcome screen plus
            // a brand-new window playing the file.
            if (_player_window == null) {
                _player_window = new PlayerWindow (this);
            }
            _player_window.present ();
        }

        public override void open (GLib.File[] files, string hint) {
            activate ();
            if (files.length == 0 || _player_window == null) return;
            if (_trim_files) {
                _trim_files = false;
                _player_window.open_trim_files (files);
                return;
            }
            _player_window.open_file (files[0]);
        }
    }
}
