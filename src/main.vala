using Singularity.Apps.Videos;

int main (string[] args) {
    var app = new VideosApp ();
    return app.run (args);
}

namespace Singularity.Apps.Videos {

    public class VideosApp : Singularity.Application {

        private PlayerWindow? _player_window = null;

        public VideosApp () {
            GLib.Object (application_id: "dev.sinty.videos",
                         flags: GLib.ApplicationFlags.HANDLES_OPEN);
        }

        protected override void startup () {
            base.startup ();

            var file_menu = new GLib.Menu ();
            file_menu.append ("Open Video…", "app.open");
            file_menu.append ("Quit", "app.quit");
            var menu = new GLib.Menu ();
            menu.append_submenu ("File", file_menu);
            set_menubar (menu);

            var act_open = new GLib.SimpleAction ("open", null);
            act_open.activate.connect (() => {
                if (_player_window != null) _player_window.open_file_dialog ();
            });
            add_action (act_open);

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
            if (files.length > 0 && _player_window != null)
                _player_window.open_file (files[0]);
        }
    }
}
