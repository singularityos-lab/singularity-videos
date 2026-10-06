namespace Singularity.Apps.Videos {

    public class TrimView : Gtk.Box {

        private const int THUMBNAILS = 12;
        private const int64 SECOND = NS_PER_SECOND;

        public signal void load_failed (string message);
        public signal void loaded ();

        public EditList edl {
            get { return _edl; }
        }

        private EditList _edl = new EditList ();

        public bool modified { get; set; default = false; }

        public bool has_media {
            get { return edl.size > 0; }
        }

        private GstPlayer _player;
        private TrimCanvas _canvas;
        private TrimTimeline _timeline;
        private Gtk.Label _clip_label;
        private Gtk.Label _timecode;
        private Gtk.Label _frame_label;
        private Gtk.Label _length_label;
        private Gtk.Button _play_btn;
        private Gtk.ToggleButton _crop_btn;
        private Gtk.MenuButton _aspect_btn;
        private Gtk.Button _cut_btn;
        private Gtk.Button _mark_in_btn;
        private Gtk.Button _mark_out_btn;
        private Gtk.Button _restore_btn;
        private Gtk.Button _earlier_btn;
        private Gtk.Button _later_btn;
        private Gtk.Button _remove_btn;
        private Gtk.FileChooserNative? _chooser = null;

        private int _current = -1;
        private bool _playing = false;
        private uint _tick_id = 0;
        private uint _seek_retry_id = 0;
        private int64 _last_seek_us = 0;
        private int64 _position = 0;
        private Gee.ArrayList<GLib.File> _queue = new Gee.ArrayList<GLib.File> ();
        private bool _probing = false;
        private bool _probing_first = false;

        construct {
            orientation = Gtk.Orientation.VERTICAL;
            spacing = 0;
            add_css_class ("videos-trim");

            _player = new GstPlayer ();
            _player.finished.connect (_on_clip_end);
            _player.error_occurred.connect ((msg) => load_failed (msg));

            _canvas = new TrimCanvas ();
            _canvas.set_paintable (_player.paintable);
            _canvas.crop_changed.connect ((box, final) => {
                if (final) edl.set_crop (box);
            });
            append (_canvas);

            append (_build_viewer_strip ());

            _timeline = new TrimTimeline ();
            _timeline.set_list (edl);
            _timeline.margin_start = 12;
            _timeline.margin_end = 12;
            _timeline.scrub.connect (_on_scrub);
            _timeline.clip_selected.connect ((i) => {
                _timeline.mark_in = -1;
                _timeline.mark_out = -1;
                _sync_tools ();
            });
            _timeline.trim_changed.connect (() => _sync_labels ());
            append (_timeline);

            append (_build_clip_strip ());

            edl.changed.connect (() => {
                if (!_probing_first) modified = true;
                _sync_labels ();
                _sync_tools ();
                _canvas.rotation = edl.rotation;
                _canvas.crop = edl.crop;
            });

            var keys = new Gtk.EventControllerKey ();
            keys.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            keys.key_pressed.connect (_on_key);
            add_controller (keys);

            _tick_id = GLib.Timeout.add (33, () => {
                _tick ();
                return GLib.Source.CONTINUE;
            });
            destroy.connect (() => {
                if (_tick_id != 0) GLib.Source.remove (_tick_id);
                _tick_id = 0;
            });
            _sync_tools ();
        }

        private Gtk.Widget _build_viewer_strip () {
            var bar = new Singularity.Widgets.ControlStrip (6, 6);
            bar.add_css_class ("videos-trim-strip");

            var nav = bar.add_group ();
            bar.add_icon_button ("media-skip-backward-symbolic", _("Clip Start (Home)"), nav).clicked.connect (() => go_to_edge (false));
            bar.add_icon_button ("media-seek-backward-symbolic", _("Previous Frame (Left)"), nav).clicked.connect (() => step_frames (-1));
            _play_btn = bar.add_icon_button ("media-playback-start-symbolic", _("Play (Space)"), nav);
            _play_btn.clicked.connect (() => toggle_play ());
            bar.add_icon_button ("media-seek-forward-symbolic", _("Next Frame (Right)"), nav).clicked.connect (() => step_frames (1));
            bar.add_icon_button ("media-skip-forward-symbolic", _("Clip End (End)"), nav).clicked.connect (() => go_to_edge (true));

            _timecode = bar.add_numeric_label ();
            _timecode.label = format_timecode (0);
            _timecode.add_css_class ("videos-trim-timecode");
            _frame_label = bar.add_numeric_label ();
            _frame_label.add_css_class ("dim-label");

            bar.add_separator ();
            var range = bar.add_group ();
            bar.add_icon_button ("videos-trim-start-symbolic", _("Start Here ([)"), range).clicked.connect (() => set_start ());
            bar.add_icon_button ("videos-trim-end-symbolic", _("End Here (])"), range).clicked.connect (() => set_end ());

            bar.add_separator ();
            var marks = bar.add_group ();
            _mark_in_btn = bar.add_icon_button ("videos-mark-in-symbolic", _("Mark In (I)"), marks);
            _mark_in_btn.clicked.connect (() => mark_in ());
            _mark_out_btn = bar.add_icon_button ("videos-mark-out-symbolic", _("Mark Out (O)"), marks);
            _mark_out_btn.clicked.connect (() => mark_out ());
            _cut_btn = bar.add_icon_button ("edit-cut-symbolic", _("Cut Selection (Delete)"), marks);
            _cut_btn.clicked.connect (() => cut_selection ());
            _restore_btn = bar.add_icon_button ("videos-restore-cut-symbolic", _("Restore Removed Part"), marks);
            _restore_btn.clicked.connect (() => restore_cut ());

            bar.add_spacer ();
            var frame = bar.add_group ();
            _crop_btn = bar.add_icon_toggle ("singularity-markup-crop-symbolic", _("Crop (C)"), frame);
            _crop_btn.toggled.connect (() => _canvas.crop_mode = _crop_btn.active);
            _aspect_btn = bar.add_icon_menu ("videos-aspect-ratio-symbolic", _("Crop Ratio"), _aspect_menu (), frame);
            _aspect_btn.direction = Gtk.ArrowType.UP;
            bar.add_icon_button ("object-rotate-left-symbolic", _("Rotate Left"), frame).clicked.connect (() => rotate (-1));
            bar.add_icon_button ("object-rotate-right-symbolic", _("Rotate Right"), frame).clicked.connect (() => rotate (1));

            var group = new GLib.SimpleActionGroup ();
            var ratio = new GLib.SimpleAction ("ratio", GLib.VariantType.STRING);
            ratio.activate.connect ((p) => set_ratio (p.get_string ()));
            group.add_action (ratio);
            insert_action_group ("trim", group);
            return bar;
        }

        private Gtk.Widget _build_clip_strip () {
            var bar = new Singularity.Widgets.ControlStrip (6, 8);
            bar.add_css_class ("videos-trim-strip");

            _clip_label = new Gtk.Label ("");
            _clip_label.xalign = 0;
            _clip_label.ellipsize = Pango.EllipsizeMode.MIDDLE;
            _clip_label.hexpand = true;
            _clip_label.add_css_class ("videos-trim-clip");
            bar.append (_clip_label);

            _length_label = bar.add_numeric_label ();
            _length_label.add_css_class ("dim-label");

            bar.add_separator ();
            var clips = bar.add_group ();
            bar.add_icon_button ("list-add-symbolic", _("Add Clips"), clips).clicked.connect (() => add_clips_dialog ());
            _earlier_btn = bar.add_icon_button ("go-previous-symbolic", _("Move Clip Earlier"), clips);
            _earlier_btn.clicked.connect (() => move_selected (-1));
            _later_btn = bar.add_icon_button ("go-next-symbolic", _("Move Clip Later"), clips);
            _later_btn.clicked.connect (() => move_selected (1));
            _remove_btn = bar.add_icon_button ("user-trash-symbolic", _("Remove Clip"), clips);
            _remove_btn.clicked.connect (() => remove_selected ());

            return bar;
        }

        private GLib.Menu _aspect_menu () {
            var menu = new GLib.Menu ();
            var ratios = new GLib.Menu ();
            string[,] items = {
                { _("Free"), "free" },
                { _("Original"), "original" },
                { _("Widescreen 16:9"), "16:9" },
                { _("Standard 4:3"), "4:3" },
                { _("Square 1:1"), "1:1" },
                { _("Portrait 4:5"), "4:5" },
                { _("Vertical 9:16"), "9:16" }
            };
            for (int i = 0; i < items.length[0]; i++) {
                var item = new GLib.MenuItem (items[i, 0], null);
                item.set_action_and_target_value ("trim.ratio", new GLib.Variant.string (items[i, 1]));
                ratios.append_item (item);
            }
            menu.append_section (null, ratios);
            var reset = new GLib.Menu ();
            var item = new GLib.MenuItem (_("Reset Crop"), null);
            item.set_action_and_target_value ("trim.ratio", new GLib.Variant.string ("reset"));
            reset.append_item (item);
            menu.append_section (null, reset);
            return menu;
        }

        public void open_file (GLib.File file) {
            stop ();
            edl.reset ();
            modified = false;
            _crop_btn.active = false;
            _canvas.aspect = 0;
            _current = -1;
            _position = 0;
            _timeline.selected = 0;
            _timeline.mark_in = -1;
            _timeline.mark_out = -1;
            add_file (file, true);
        }

        public void add_file (GLib.File file, bool first = false) {
            _queue.add (file);
            if (!_probing) _probe_next (first);
        }

        private void _probe_next (bool first) {
            if (_queue.size == 0) {
                _probing = false;
                return;
            }
            _probing = true;
            var file = _queue.remove_at (0);
            MediaProbe.probe.begin (file.get_uri (), (obj, res) => {
                string? error;
                var clip = MediaProbe.probe.end (res, out error);
                if (clip == null) {
                    load_failed (_("Could not open %s: %s").printf (file.get_basename (), error ?? ""));
                } else {
                    var strip = new MediaStrip (clip.uri, clip.duration);
                    _timeline.attach_strip (clip, strip);
                    strip.load (THUMBNAILS, clip.has_video, clip.has_audio);
                    _probing_first = first;
                    edl.add (clip);
                    _probing_first = false;
                    if (_current < 0) _show (0, 0);
                    if (first) loaded ();
                }
                _probe_next (false);
            });
        }

        public void add_clips_dialog () {
            var win = get_root () as Gtk.Window;
            _chooser = new Gtk.FileChooserNative (_("Add Clips"), win, Gtk.FileChooserAction.OPEN, _("Add"), _("Cancel"));
            _chooser.select_multiple = true;
            var filter = new Gtk.FileFilter ();
            filter.add_mime_type ("video/*");
            filter.add_mime_type ("audio/*");
            filter.name = _("Media Files");
            _chooser.add_filter (filter);
            _chooser.response.connect ((id) => {
                if (id == Gtk.ResponseType.ACCEPT) {
                    var files = _chooser.get_files ();
                    for (uint i = 0; i < files.get_n_items (); i++) {
                        var f = files.get_item (i) as GLib.File;
                        if (f != null) add_file (f);
                    }
                }
                _chooser = null;
            });
            _chooser.show ();
        }

        public void stop () {
            _playing = false;
            _player.pause ();
            _update_play_icon ();
        }

        public void shutdown () {
            stop ();
            _player.close ();
        }

        private EditClip? _selected_clip () {
            int i = _timeline.selected;
            if (i < 0 || i >= edl.size) return null;
            return edl.get_clip (i);
        }

        private void _show (int index, int64 local, bool play = false) {
            if (index < 0 || index >= edl.size) return;
            var clip = edl.get_clip (index);
            _timeline.selected = index;
            _position = local;
            _timeline.set_playhead (index, local);
            if (index != _current) {
                _current = index;
                _player.open_paused (clip.uri);
                _retry_seek (local, play);
            } else {
                _player.seek_ns (local);
                if (play) _player.play ();
            }
            _sync_labels ();
            _sync_tools ();
        }

        private void _retry_seek (int64 local, bool play) {
            if (_seek_retry_id != 0) GLib.Source.remove (_seek_retry_id);
            int attempts = 0;
            _seek_retry_id = GLib.Timeout.add (50, () => {
                if (_player.duration_ns () > 0) {
                    _player.seek_ns (local);
                    if (play) _player.play ();
                    _seek_retry_id = 0;
                    return GLib.Source.REMOVE;
                }
                if (++attempts > 100) {
                    _seek_retry_id = 0;
                    return GLib.Source.REMOVE;
                }
                return GLib.Source.CONTINUE;
            });
        }

        private void _on_scrub (int clip, int64 local, bool final) {
            if (_playing) stop ();
            _position = local;
            if (clip != _current) {
                _show (clip, local);
                return;
            }
            int64 now = GLib.get_monotonic_time ();
            if (!final && now - _last_seek_us < 40000) {
                _sync_labels ();
                return;
            }
            _last_seek_us = now;
            _player.seek_ns (local);
            _sync_labels ();
            _sync_tools ();
        }

        private void _tick () {
            if (_current < 0 || _current >= edl.size || _seek_retry_id != 0) return;
            var clip = edl.get_clip (_current);
            if (!_playing) return;
            int64 pos = _player.position_ns ();
            var cut = clip.cut_at (pos);
            if (cut != null) {
                _player.seek_ns (cut.end);
                pos = cut.end;
            }
            if (pos < clip.in_point) {
                _player.seek_ns (clip.in_point);
                pos = clip.in_point;
            }
            if (pos >= clip.out_point - clip.frame_duration () / 2) {
                _on_clip_end ();
                return;
            }
            _position = pos;
            _timeline.set_playhead (_current, pos);
            _sync_labels ();
        }

        private void _on_clip_end () {
            if (!_playing) return;
            for (int i = _current + 1; i < edl.size; i++) {
                var next = edl.get_clip (i);
                var kept = next.kept_ranges ();
                if (kept.length == 0) continue;
                _show (i, kept[0].start, true);
                return;
            }
            stop ();
            var clip = edl.get_clip (_current);
            _position = clip.out_point;
            _player.seek_ns (clip.snap (clip.out_point - clip.frame_duration ()));
            _timeline.set_playhead (_current, _position);
            _sync_labels ();
        }

        public void toggle_play () {
            if (_current < 0) return;
            if (_playing) {
                stop ();
                return;
            }
            var clip = edl.get_clip (_current);
            int64 pos = _player.position_ns ();
            int64 next = clip.next_kept (pos);
            if (next < 0 || pos >= clip.out_point - clip.frame_duration ()) {
                int first = -1;
                for (int i = 0; i < edl.size && first < 0; i++) {
                    if (edl.get_clip (i).kept_ranges ().length > 0) first = i;
                }
                if (first < 0) return;
                _playing = true;
                _update_play_icon ();
                _show (first, edl.get_clip (first).kept_ranges ()[0].start, true);
                return;
            }
            if (next != pos) _player.seek_ns (next);
            _playing = true;
            _player.play ();
            _update_play_icon ();
        }

        public void step_frames (int frames) {
            if (_current < 0) return;
            stop ();
            var clip = edl.get_clip (_current);
            int64 target = clip.snap (clip.snap (_position) + frames * clip.frame_duration ());
            target = target.clamp (0, int64.max (0, clip.duration - clip.frame_duration ()));
            _position = target;
            _player.seek_ns (target);
            _timeline.set_playhead (_current, target);
            _sync_labels ();
            _sync_tools ();
        }

        public void seek_by (int64 delta) {
            if (_current < 0) return;
            var clip = edl.get_clip (_current);
            int64 target = clip.snap ((_position + delta).clamp (0, clip.duration));
            _position = target;
            _player.seek_ns (target);
            _timeline.set_playhead (_current, target);
            _sync_labels ();
        }

        public void go_to_edge (bool end) {
            var clip = _selected_clip ();
            if (clip == null) return;
            int64 t = end ? clip.snap (clip.out_point - clip.frame_duration ()) : clip.in_point;
            _on_scrub (_timeline.selected, t, true);
            _timeline.set_playhead (_timeline.selected, _position);
        }

        public void set_start () {
            var clip = _selected_clip ();
            if (clip == null) return;
            int64 t = clip.snap (_position);
            if (t >= clip.out_point) return;
            clip.set_trim (t, clip.out_point);
            edl.notify_changed ();
        }

        public void set_end () {
            var clip = _selected_clip ();
            if (clip == null) return;
            int64 t = clip.snap (_position);
            if (t <= clip.in_point) return;
            clip.set_trim (clip.in_point, t);
            edl.notify_changed ();
        }

        public void mark_in () {
            var clip = _selected_clip ();
            if (clip == null) return;
            _timeline.mark_in = clip.snap (_position);
            if (_timeline.mark_out >= 0 && _timeline.mark_out <= _timeline.mark_in) _timeline.mark_out = -1;
            _sync_tools ();
        }

        public void mark_out () {
            var clip = _selected_clip ();
            if (clip == null) return;
            _timeline.mark_out = clip.snap (_position);
            if (_timeline.mark_in < 0 || _timeline.mark_in >= _timeline.mark_out) _timeline.mark_in = clip.in_point;
            _sync_tools ();
        }

        public void cut_selection () {
            var clip = _selected_clip ();
            if (clip == null || _timeline.mark_in < 0 || _timeline.mark_out <= _timeline.mark_in) return;
            clip.add_cut (_timeline.mark_in, _timeline.mark_out);
            _timeline.mark_in = -1;
            _timeline.mark_out = -1;
            edl.notify_changed ();
        }

        public void restore_cut () {
            var clip = _selected_clip ();
            if (clip == null) return;
            if (clip.remove_cut_at (_position)) edl.notify_changed ();
        }

        public void rotate (int turns) {
            edl.rotate_by (turns);
            if (_canvas.aspect > 0) _canvas.aspect = 1.0 / _canvas.aspect;
        }

        public void set_ratio (string name) {
            int w, h;
            edl.source_size (out w, out h);
            if (w <= 0 || h <= 0) _canvas.frame_size (out w, out h);
            int rw, rh;
            Geometry.rotated_size (w, h, edl.rotation, out rw, out rh);
            if (name == "reset") {
                _canvas.aspect = 0;
                edl.set_crop (new CropBox ());
                return;
            }
            if (name == "free") {
                _canvas.aspect = 0;
                _crop_btn.active = true;
                return;
            }
            double aspect;
            if (name == "original") {
                aspect = (double) rw / rh;
            } else {
                var p = name.split (":");
                aspect = double.parse (p[0]) / double.parse (p[1]);
            }
            _canvas.aspect = aspect;
            edl.set_crop (CropBox.with_aspect (aspect, rw, rh));
            _crop_btn.active = true;
        }

        public void move_selected (int delta) {
            int i = _timeline.selected;
            if (!edl.move (i, i + delta)) return;
            _timeline.selected = i + delta;
            if (_current == i) _current = i + delta;
            else if (_current == i + delta) _current = i;
            _sync_tools ();
        }

        public void remove_selected () {
            int i = _timeline.selected;
            if (edl.size <= 1 || i < 0 || i >= edl.size) return;
            var clip = edl.get_clip (i);
            _timeline.detach_strip (clip);
            edl.remove_at (i);
            if (_current == i) {
                _current = -1;
                _show (int.min (i, edl.size - 1), 0);
            } else if (_current > i) {
                _current--;
            }
            _timeline.selected = int.min (i, edl.size - 1);
            _sync_tools ();
        }

        private void _update_play_icon () {
            _play_btn.icon_name = _playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic";
            _play_btn.tooltip_text = _playing ? _("Pause (Space)") : _("Play (Space)");
        }

        private void _sync_labels () {
            if (_current < 0 || _current >= edl.size) {
                _clip_label.label = "";
                _length_label.label = "";
                _timecode.label = format_timecode (0);
                _frame_label.label = "";
                return;
            }
            var clip = edl.get_clip (_current);
            _clip_label.label = edl.size > 1
                ? _("Clip %d of %d: %s").printf (_current + 1, edl.size, clip.display_name ())
                : clip.display_name ();
            _length_label.label = _("Result %s").printf (format_timecode (edl.output_duration ()));
            _timecode.label = format_timecode (_position);
            _frame_label.label = _("Frame %lld").printf (clip.frame_at (_position));
        }

        private void _sync_tools () {
            if (_cut_btn == null) return;
            var clip = _selected_clip ();
            _cut_btn.sensitive = clip != null && _timeline.mark_in >= 0 && _timeline.mark_out > _timeline.mark_in;
            _restore_btn.sensitive = clip != null && clip.cut_at (_position) != null;
            _earlier_btn.sensitive = _timeline.selected > 0;
            _later_btn.sensitive = _timeline.selected < edl.size - 1;
            _remove_btn.sensitive = edl.size > 1;
            _set_checked (_mark_in_btn, clip != null && _timeline.mark_in >= 0);
            _set_checked (_mark_out_btn, clip != null && _timeline.mark_out >= 0);
        }

        private static void _set_checked (Gtk.Widget w, bool on) {
            if (on) w.set_state_flags (Gtk.StateFlags.CHECKED, false);
            else w.unset_state_flags (Gtk.StateFlags.CHECKED);
        }

        private bool _on_key (uint keyval, uint keycode, Gdk.ModifierType state) {
            var mods = Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK | Gdk.ModifierType.SUPER_MASK;
            if ((state & mods) != 0) return false;
            bool shift = (state & Gdk.ModifierType.SHIFT_MASK) != 0;
            switch (keyval) {
                case Gdk.Key.space:
                case Gdk.Key.KP_Space:
                    toggle_play ();
                    return true;
                case Gdk.Key.Left:
                    if (shift) seek_by (-SECOND); else step_frames (-1);
                    return true;
                case Gdk.Key.Right:
                    if (shift) seek_by (SECOND); else step_frames (1);
                    return true;
                case Gdk.Key.comma:
                    step_frames (-1);
                    return true;
                case Gdk.Key.period:
                    step_frames (1);
                    return true;
                case Gdk.Key.i:
                case Gdk.Key.I:
                    mark_in ();
                    return true;
                case Gdk.Key.o:
                case Gdk.Key.O:
                    mark_out ();
                    return true;
                case Gdk.Key.bracketleft:
                    set_start ();
                    return true;
                case Gdk.Key.bracketright:
                    set_end ();
                    return true;
                case Gdk.Key.Delete:
                case Gdk.Key.BackSpace:
                    cut_selection ();
                    return true;
                case Gdk.Key.Home:
                    go_to_edge (false);
                    return true;
                case Gdk.Key.End:
                    go_to_edge (true);
                    return true;
                case Gdk.Key.c:
                case Gdk.Key.C:
                    _crop_btn.active = !_crop_btn.active;
                    return true;
                default:
                    return false;
            }
        }
    }
}
