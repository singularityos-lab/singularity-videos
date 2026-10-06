using Singularity.MediaSources;

namespace Singularity.Apps.Videos {

    public class MediaBin : Singularity.Widgets.AppSidebar {
        public const string RECENT = "recent";

        private Gtk.Box _library = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        private Gtk.Box _sources = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        private Singularity.Widgets.SidebarSectionLabel _sources_label;
        private Gee.HashMap<string, Singularity.Widgets.SidebarRow> _rows = new Gee.HashMap<string, Singularity.Widgets.SidebarRow> ();
        private Singularity.Widgets.SearchBubble _search;
        private string _active = "";

        public signal void navigate (string source_id, string title);
        public signal void search_submitted (string text);
        public signal void search_cleared ();
        public signal void search_typed (string text);
        public signal void open_files ();
        public signal void open_address ();

        public MediaBin () {
            base (240);
            add_css_class ("sx-media-bin");
            add_bubble_icon ("document-open-symbolic", _("Open Video (Ctrl+O)"), () => open_files ());
            add_bubble_icon ("insert-link-symbolic", _("Open Address (Ctrl+L)"), () => open_address ());
            _search = add_bubble_search (_("Search"), (t) => {
                if (t.strip () == "") search_cleared ();
                else search_typed (t.strip ());
            });
            _search.entry.activate.connect (() => {
                string t = _search.text.strip ();
                if (t != "") search_submitted (t);
            });

            box.append (new Singularity.Widgets.SidebarSectionLabel (_("Library")));
            box.append (_library);
            _add_row (_library, LocalVideosSource.ID, "folder-videos-symbolic", _("Videos"));
            _add_row (_library, RECENT, "document-open-recent-symbolic", _("Recent"));

            _sources_label = new Singularity.Widgets.SidebarSectionLabel (_("Sources"));
            box.append (_sources_label);
            box.append (_sources);
            _update_sections ();
        }

        private Singularity.Widgets.SidebarRow _add_row (Gtk.Box parent, string id, string icon, string title) {
            var row = new Singularity.Widgets.SidebarRow (icon, title);
            row.clicked.connect (() => {
                set_active (id);
                navigate (id, title);
            });
            _rows[id] = row;
            parent.append (row);
            return row;
        }

        public void set_active (string id) {
            _active = id;
            foreach (var e in _rows.entries) e.value.set_active (e.key == id);
        }

        public string active { get { return _active; } }

        public void focus_search () {
            if (!_search.get_child_visible ()) {
                var proxy = _search.get_next_sibling () as Gtk.Button;
                if (proxy != null) {
                    proxy.grab_focus ();
                    proxy.clicked ();
                    return;
                }
            }
            _search.grab_focus_entry ();
        }

        public void clear_search () {
            _search.clear ();
        }

        public void add_source (MediaSource source) {
            if (source.id == LocalVideosSource.ID || _rows.has_key (source.id)) return;
            _add_row (_sources, source.id, source.icon_name, source.title);
            _update_sections ();
        }

        public void remove_source (string id) {
            var row = _rows[id];
            if (row == null) return;
            _rows.unset (id);
            _sources.remove (row);
            _update_sections ();
        }

        private void _update_sections () {
            _sources_label.visible = _sources.get_first_child () != null;
        }
    }
}
