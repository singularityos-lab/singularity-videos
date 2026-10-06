using Singularity.MediaSources;

namespace Singularity.Apps.Videos {

    public class EmbedPage : Gtk.Box {
        private Gtk.Stack _stack;
        private Gtk.Box _slot;
        private Singularity.Widgets.StatusPage _status;
        private Gtk.Button _status_action;
        private EmbeddedPlayer? _player = null;
        private ulong _state_handler = 0;
        private ulong _ended_handler = 0;
        private ulong _failed_handler = 0;

        public MediaItem? item { get; private set; default = null; }
        public string external_uri { get; private set; default = ""; }

        public signal void state_changed ();
        public signal void open_uri (string uri);

        construct {
            orientation = Gtk.Orientation.VERTICAL;
            hexpand = true;
            vexpand = true;
            add_css_class ("videos-embed");
            _stack = new Gtk.Stack ();
            _stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
            _stack.vexpand = true;
            _slot = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            _slot.hexpand = true;
            _slot.vexpand = true;
            _slot.add_css_class ("videos-embed-slot");
            Singularity.Widgets.apply_view_edge (_slot);
            _stack.add_named (_slot, "player");
            _status = new Singularity.Widgets.StatusPage ();
            _status.icon_name = "video-x-generic";
            _status.vexpand = true;
            _status_action = new Gtk.Button.with_label (_("Open in Browser"));
            _status_action.add_css_class ("pill");
            _status_action.add_css_class ("suggested-action");
            _status_action.halign = Gtk.Align.CENTER;
            _status_action.clicked.connect (() => {
                if (external_uri != "") open_uri (external_uri);
            });
            _status.child = _status_action;
            _stack.add_named (_status, "status");
            append (_stack);
        }

        public EmbeddedPlayer? player { get { return _player; } }

        public void show_player (EmbeddedPlayer player, MediaItem item, string external_uri, int64 start_ms) {
            release ();
            _player = player;
            this.item = item;
            this.external_uri = external_uri != "" ? external_uri : item.external_url;
            var w = player.widget;
            w.hexpand = true;
            w.vexpand = true;
            w.set_size_request (player.min_width, player.min_height);
            _slot.append (w);
            _state_handler = player.state_changed.connect (() => state_changed ());
            _ended_handler = player.ended.connect (() => state_changed ());
            _failed_handler = player.failed.connect ((msg) => {
                _status.title = _("Can't Play This Video Here");
                _status.description = msg != "" ? msg : _("The service did not start its player.");
                _status_action.visible = this.external_uri != "";
                _stack.visible_child_name = "status";
                state_changed ();
            });
            _stack.visible_child_name = "player";
            player.load (item, start_ms);
        }

        public void release () {
            if (_player != null) {
                if (_state_handler != 0) _player.disconnect (_state_handler);
                if (_ended_handler != 0) _player.disconnect (_ended_handler);
                if (_failed_handler != 0) _player.disconnect (_failed_handler);
                _state_handler = _ended_handler = _failed_handler = 0;
                _player.stop ();
                var w = _player.widget;
                if (w.get_parent () == _slot) _slot.remove (w);
            }
            _player = null;
            item = null;
            state_changed ();
        }

        public bool playing {
            get { return _player != null && _player.state == PlaybackState.PLAYING; }
        }
    }
}
