using Singularity.Apps.Videos;

[ModuleInit]
public void peas_register_types (GLib.TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type (typeof (Singularity.Plugin), typeof (VideosRecentPlugin));
}

public class VideosRecentMenu : GLib.Object, Singularity.DockContextMenuProvider {
    private const int LIMIT = 5;

    public bool populate_context_menu (Singularity.Widgets.ContextMenu menu, Singularity.DockContextMenuRequest request) {
        string id = request.app_id.has_suffix (".desktop") ? request.app_id.substring (0, request.app_id.length - 8) : request.app_id;
        if (id != "dev.sinty.videos") return false;
        var history = new VideoHistory ();
        var recent = history.recent (LIMIT);
        if (recent.length == 0) return false;
        var header = new Gtk.Label (_("Recent Videos"));
        header.add_css_class ("caption");
        header.add_css_class ("dim-label");
        header.xalign = 0;
        header.margin_start = 12;
        header.margin_top = 4;
        header.margin_bottom = 2;
        menu.add_widget (header);
        foreach (var entry in recent) {
            string uri = entry.uri;
            menu.add_item (VideoHistory.label_for (entry),
                entry.resumable ? "media-playback-start-symbolic" : "video-x-generic-symbolic", () => open (uri));
        }
        return true;
    }

    private void open (string uri) {
        var info = new GLib.DesktopAppInfo ("dev.sinty.videos.desktop");
        if (info == null) return;
        var files = new GLib.List<GLib.File> ();
        files.append (GLib.File.new_for_uri (uri));
        try {
            info.launch (files, Gdk.Display.get_default ().get_app_launch_context ());
        } catch (GLib.Error e) {
            warning ("videos-recent: %s", e.message);
        }
    }
}

public class VideosRecentPlugin : GLib.Object, Singularity.Plugin {
    private Singularity.PluginContext? context = null;
    private VideosRecentMenu provider = new VideosRecentMenu ();

    public void activate (Singularity.PluginContext context) {
        this.context = context;
        context.add_dock_context_menu_provider (provider);
    }

    public void deactivate () {
        if (context != null) context.remove_dock_context_menu_provider (provider);
        context = null;
    }

    public Gtk.Widget? get_settings_widget () {
        return null;
    }
}
