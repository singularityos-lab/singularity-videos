namespace Singularity.Apps.Videos {

    public class ExportDialog : Singularity.Widgets.AppDialog {

        public signal void exported (string path);

        private EditList _edl;
        private ExportFormat _format = ExportFormat.MP4;
        private ExportQuality _quality = ExportQuality.MEDIUM;
        private GLib.File _folder;
        private string _base_name;
        private ExportBackend? _backend = null;

        private Gtk.Stack _stack;
        private Gtk.Button _cancel;
        private Gtk.Button _export;
        private Gtk.Button _show_btn;
        private Singularity.Widgets.ActionRow _dest_row;
        private Singularity.Widgets.ActionRow[] _quality_rows = {};
        private Gtk.ProgressBar _progress;
        private Gtk.Label _progress_label;
        private Gtk.Label _progress_detail;
        private Gtk.Label _done_detail;
        private Gtk.Label _error_label;
        private Gtk.FileChooserNative? _chooser = null;
        private string _output = "";

        public ExportDialog (Gtk.Application app, Gtk.Window parent, EditList edl, string source_name) {
            base (app, true);
            transient_for = parent;
            set_title (_("Export Video"));
            set_default_size (480, -1);
            resizable = false;
            _edl = edl;
            string stem = source_name;
            int dot = stem.last_index_of (".");
            if (dot > 0) stem = stem.substring (0, dot);
            _base_name = _("%s (Edited)").printf (stem);
            string? videos = GLib.Environment.get_user_special_dir (GLib.UserDirectory.VIDEOS);
            _folder = GLib.File.new_for_path (videos != null && GLib.FileUtils.test (videos, GLib.FileTest.IS_DIR)
                ? videos : GLib.Environment.get_home_dir ());
            if (!Encoders.available (ExportFormat.MP4) && Encoders.available (ExportFormat.WEBM))
                _format = ExportFormat.WEBM;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 16);
            box.margin_top = 6;
            box.margin_bottom = 20;
            box.margin_start = 24;
            box.margin_end = 24;

            _stack = new Gtk.Stack ();
            _stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
            _stack.transition_duration = Singularity.Motion.reduced () ? 0 : Singularity.Motion.Duration.MEDIUM.ms ();
            _stack.vhomogeneous = false;
            _stack.add_named (_build_settings (), "settings");
            _stack.add_named (_build_progress (), "progress");
            _stack.add_named (_build_done (), "done");
            box.append (_stack);

            _error_label = new Gtk.Label ("");
            _error_label.wrap = true;
            _error_label.max_width_chars = 50;
            _error_label.xalign = 0;
            _error_label.visible = false;
            _error_label.add_css_class ("error");
            box.append (_error_label);

            var buttons = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            buttons.halign = Gtk.Align.END;
            _cancel = new Gtk.Button.with_label (_("Cancel"));
            _cancel.clicked.connect (_on_cancel);
            set_cancel_button (_cancel);
            _show_btn = new Gtk.Button.with_label (_("Show in Folder"));
            _show_btn.visible = false;
            _show_btn.clicked.connect (_show_in_folder);
            _export = new Gtk.Button.with_label (_("Export"));
            _export.add_css_class ("suggested-action");
            _export.clicked.connect (_start);
            buttons.append (_cancel);
            buttons.append (_show_btn);
            buttons.append (_export);
            box.append (buttons);
            content_box.append (box);

            close_request.connect (() => {
                if (_backend != null && _backend.running) _backend.cancel ();
                return false;
            });
            _sync ();
        }

        private Gtk.Widget _build_settings () {
            var page = new Gtk.Box (Gtk.Orientation.VERTICAL, 16);

            var format_group = new Singularity.Widgets.PreferencesGroup (_("Format"));
            Gtk.CheckButton? first = null;
            foreach (var f in new ExportFormat[] { ExportFormat.MP4, ExportFormat.WEBM }) {
                bool ok = Encoders.available (f);
                var row = new Singularity.Widgets.ActionRow (f.label (),
                    ok ? f.codecs () : _("Not available: the %s encoders are not installed").printf (f.codecs ()));
                var check = new Gtk.CheckButton ();
                check.valign = Gtk.Align.CENTER;
                if (first == null) first = check;
                else check.group = first;
                check.active = f == _format;
                check.sensitive = ok;
                row.sensitive = ok;
                var fmt = f;
                check.toggled.connect (() => {
                    if (!check.active) return;
                    _format = fmt;
                    _sync ();
                });
                row.activated.connect (() => {
                    if (ok) check.active = true;
                });
                row.add_prefix (check);
                format_group.add_row (row);
            }
            page.append (format_group);

            var quality_group = new Singularity.Widgets.PreferencesGroup (_("Quality"));
            Gtk.CheckButton? qfirst = null;
            foreach (var q in new ExportQuality[] { ExportQuality.HIGH, ExportQuality.MEDIUM, ExportQuality.SMALL }) {
                var preset = new ExportPreset (q);
                var row = new Singularity.Widgets.ActionRow (preset.label (), preset.summary ());
                var check = new Gtk.CheckButton ();
                check.valign = Gtk.Align.CENTER;
                if (qfirst == null) qfirst = check;
                else check.group = qfirst;
                check.active = q == _quality;
                var size = new Gtk.Label ("");
                size.add_css_class ("dim-label");
                size.add_css_class ("videos-export-size");
                row.add_suffix (size);
                var qual = q;
                check.toggled.connect (() => {
                    if (!check.active) return;
                    _quality = qual;
                    _sync ();
                });
                row.activated.connect (() => check.active = true);
                row.add_prefix (check);
                row.set_data<Gtk.Label> ("size-label", size);
                row.set_data<int> ("quality", (int) q);
                quality_group.add_row (row);
                _quality_rows += row;
            }
            page.append (quality_group);

            var dest_group = new Singularity.Widgets.PreferencesGroup (_("Save To"));
            _dest_row = new Singularity.Widgets.ActionRow ("", "");
            var change = new Gtk.Button.with_label (_("Change…"));
            change.valign = Gtk.Align.CENTER;
            change.clicked.connect (_choose_destination);
            _dest_row.add_suffix (change);
            dest_group.add_row (_dest_row);
            page.append (dest_group);
            return page;
        }

        private Gtk.Widget _build_progress () {
            var page = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            page.margin_top = 12;
            page.margin_bottom = 12;
            var icon = new Gtk.Image.from_icon_name ("video-x-generic");
            icon.pixel_size = 64;
            page.append (icon);
            _progress_label = new Gtk.Label (_("Exporting"));
            _progress_label.wrap = true;
            _progress_label.max_width_chars = 36;
            _progress_label.justify = Gtk.Justification.CENTER;
            _progress_label.add_css_class ("title-3");
            page.append (_progress_label);
            _progress_detail = new Gtk.Label ("");
            _progress_detail.add_css_class ("dim-label");
            _progress_detail.wrap = true;
            _progress_detail.max_width_chars = 44;
            _progress_detail.justify = Gtk.Justification.CENTER;
            page.append (_progress_detail);
            _progress = new Gtk.ProgressBar ();
            _progress.margin_top = 8;
            _progress.show_text = true;
            page.append (_progress);
            return page;
        }

        private Gtk.Widget _build_done () {
            var page = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            page.margin_top = 12;
            page.margin_bottom = 12;
            var icon = new Gtk.Image.from_icon_name ("video-x-generic");
            icon.pixel_size = 64;
            page.append (icon);
            var title = new Gtk.Label (_("Export Complete"));
            title.add_css_class ("title-3");
            page.append (title);
            _done_detail = new Gtk.Label ("");
            _done_detail.add_css_class ("dim-label");
            _done_detail.wrap = true;
            _done_detail.max_width_chars = 44;
            _done_detail.wrap_mode = Pango.WrapMode.WORD_CHAR;
            _done_detail.justify = Gtk.Justification.CENTER;
            page.append (_done_detail);
            return page;
        }

        private string _file_name () {
            return "%s.%s".printf (_base_name, _format.extension ());
        }

        private void _sync () {
            int w, h;
            foreach (var row in _quality_rows) {
                var q = (ExportQuality) row.get_data<int> ("quality");
                var preset = new ExportPreset (q);
                _edl.output_size (preset, out w, out h);
                int64 bytes = preset.estimated_bytes (_format, w, h, _edl.output_duration ());
                row.get_data<Gtk.Label> ("size-label").label = _("%d × %d, about %s").printf (w, h, GLib.format_size (bytes));
            }
            _dest_row.title = _file_name ();
            _dest_row.subtitle = _folder.get_parse_name ();
            _export.sensitive = Encoders.available (_format) && _edl.output_duration () > 0;
        }

        private void _choose_destination () {
            _chooser = new Gtk.FileChooserNative (_("Save Video"), this, Gtk.FileChooserAction.SAVE, _("Save"), _("Cancel"));
            _chooser.set_current_name (_file_name ());
            try {
                _chooser.set_current_folder (_folder);
            } catch (GLib.Error e) {
                warning ("videos: %s", e.message);
            }
            _chooser.response.connect ((id) => {
                var f = _chooser.get_file ();
                if (id == Gtk.ResponseType.ACCEPT && f != null) {
                    var parent = f.get_parent ();
                    if (parent != null) _folder = parent;
                    string name = f.get_basename ();
                    string lower = name.down ();
                    if (lower.has_suffix (".webm") && Encoders.available (ExportFormat.WEBM)) _format = ExportFormat.WEBM;
                    else if (lower.has_suffix (".mp4") && Encoders.available (ExportFormat.MP4)) _format = ExportFormat.MP4;
                    int dot = name.last_index_of (".");
                    _base_name = dot > 0 ? name.substring (0, dot) : name;
                    _sync ();
                }
                _chooser = null;
            });
            _chooser.show ();
        }

        private string _unique_path () {
            string path = _folder.get_child (_file_name ()).get_path ();
            int n = 2;
            while (GLib.FileUtils.test (path, GLib.FileTest.EXISTS)) {
                path = _folder.get_child ("%s %d.%s".printf (_base_name, n, _format.extension ())).get_path ();
                n++;
            }
            return path;
        }

        private void _start () {
            _error_label.visible = false;
            _output = _unique_path ();
            var preset = new ExportPreset (_quality);
            int w, h;
            _edl.output_size (preset, out w, out h);
            _progress_label.label = _("Exporting %s").printf (GLib.Path.get_basename (_output));
            _progress_detail.label = _("%s, %d × %d, %s").printf (_format.label (), w, h, format_timecode (_edl.output_duration ()));
            _progress.fraction = 0;
            _progress.text = "0%";
            _stack.visible_child_name = "progress";
            _export.visible = false;
            _backend = ExportBackends.create ();
            _backend.progress.connect ((f) => {
                _progress.fraction = f;
                _progress.text = "%d%%".printf ((int) Math.round (f * 100));
            });
            _backend.finished.connect (_on_finished);
            _backend.start (_edl, _format, preset, _output);
        }

        private void _on_finished (bool ok, string? error) {
            if (ok) {
                _done_detail.label = _("Saved as %s in %s").printf (GLib.Path.get_basename (_output),
                    GLib.File.new_for_path (_output).get_parent ().get_parse_name ());
                _stack.visible_child_name = "done";
                _cancel.label = _("Done");
                _show_btn.visible = true;
                exported (_output);
                return;
            }
            _stack.visible_child_name = "settings";
            _export.visible = true;
            if (error != null) {
                _error_label.label = _("The export failed: %s").printf (error);
                _error_label.visible = true;
            }
        }

        private void _on_cancel () {
            if (_backend != null && _backend.running) {
                _backend.cancel ();
                _stack.visible_child_name = "settings";
                _export.visible = true;
                return;
            }
            close_dialog ();
        }

        private void _show_in_folder () {
            var file = GLib.File.new_for_path (_output);
            var launcher = new Gtk.FileLauncher (file);
            launcher.open_containing_folder.begin (this, null, (obj, res) => {
                try {
                    launcher.open_containing_folder.end (res);
                } catch (GLib.Error e) {
                    warning ("videos: %s", e.message);
                }
            });
        }
    }
}
