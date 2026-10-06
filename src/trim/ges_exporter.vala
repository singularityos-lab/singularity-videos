namespace Singularity.Apps.Videos {

    public class GesExporter : ExportBackend {

        private static bool _initialized = false;

        public override string backend_id {
            get { return "ges"; }
        }

        private GES.Pipeline? _pipeline = null;
        private uint _watch_id = 0;
        private uint _poll_id = 0;
        private int64 _total = 0;

        public static bool usable () {
            if (!_initialized) {
                _initialized = true;
                GES.init ();
            }
            return Encoders.has_element ("nlecomposition") && Encoders.has_element ("encodebin");
        }

        public override void start (EditList edl, ExportFormat format, ExportPreset preset, string output_path) {
            begin_run (output_path);
            string? error = null;
            if (!_setup (edl, format, preset, output_path, out error)) {
                _stop ();
                finish_run (false, error);
            }
        }

        public override void cancel () {
            if (_pipeline == null) return;
            _stop ();
            finish_run (false, null);
        }

        private bool _setup (EditList edl, ExportFormat format, ExportPreset preset, string path, out string? error) {
            error = null;
            usable ();
            _total = edl.output_duration ();
            var segments = edl.segments ();
            if (segments.length == 0 || _total <= 0) {
                error = _("Nothing is left to export.");
                return false;
            }
            var encoders = Encoders.resolve (format);
            if (!encoders.complete ()) {
                error = _("The encoders for %s are not installed.").printf (format.label ());
                return false;
            }
            int width, height, fps_n, fps_d;
            edl.output_size (preset, out width, out height);
            edl.output_framerate (out fps_n, out fps_d);

            var timeline = new GES.Timeline.audio_video ();
            var restriction = Gst.Caps.from_string (
                "video/x-raw,width=%d,height=%d,framerate=%d/%d,pixel-aspect-ratio=1/1"
                .printf (width, height, fps_n, fps_d));
            foreach (var track in timeline.get_tracks ()) {
                if (track is GES.VideoTrack) track.set_restriction_caps (restriction);
                else if (track is GES.AudioTrack)
                    track.set_restriction_caps (Gst.Caps.from_string ("audio/x-raw,rate=48000,channels=2"));
            }
            var layer = timeline.append_layer ();
            try {
                foreach (var seg in segments) {
                    var clip = edl.get_clip (seg.clip_index);
                    var asset = new GES.UriClipAsset.request_sync (seg.uri);
                    var ges_clip = layer.add_asset (asset, (Gst.ClockTime) seg.output_offset,
                                                    (Gst.ClockTime) seg.start, (Gst.ClockTime) seg.length (),
                                                    GES.TrackType.UNKNOWN);
                    if (ges_clip == null) {
                        error = _("A clip could not be added to the timeline.");
                        return false;
                    }
                    string? effect = _effect_description (edl, clip);
                    if (effect != null) {
                        ges_clip.add (new GES.Effect (effect));
                        _fit (ges_clip, edl, clip, width, height);
                    }
                }
            } catch (GLib.Error e) {
                error = e.message;
                return false;
            }
            timeline.commit_sync ();

            var profile = _profile (format, preset, encoders, width, height, fps_n, fps_d);
            _pipeline = new GES.Pipeline ();
            _pipeline.set_timeline (timeline);
            string uri = GLib.File.new_for_path (path).get_uri ();
            if (!_pipeline.set_render_settings (uri, profile) || !_pipeline.set_mode (GES.PipelineFlags.RENDER)) {
                error = _("The export could not be prepared.");
                return false;
            }
            var bus = _pipeline.get_bus ();
            _watch_id = bus.add_watch (GLib.Priority.DEFAULT, _on_message);
            _poll_id = GLib.Timeout.add (100, () => {
                int64 pos = 0;
                if (_pipeline != null && _pipeline.query_position (Gst.Format.TIME, out pos) && _total > 0)
                    position_fraction = (double) pos / _total;
                return GLib.Source.CONTINUE;
            });
            if (_pipeline.set_state (Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE) {
                error = _("The export could not start.");
                return false;
            }
            return true;
        }

        private void _fit (GES.Clip ges_clip, EditList edl, EditClip clip, int width, int height) {
            if (!clip.has_video) return;
            int cw, ch;
            Geometry.cropped_size (clip.pixel_width (), clip.height, edl.rotation, edl.crop, out cw, out ch);
            if (cw <= 0 || ch <= 0) return;
            double scale = double.min ((double) width / cw, (double) height / ch);
            int fw = int.min (width, (int) Math.round (cw * scale));
            int fh = int.min (height, (int) Math.round (ch * scale));
            _set_child (ges_clip, "width", fw);
            _set_child (ges_clip, "height", fh);
            _set_child (ges_clip, "posx", (width - fw) / 2);
            _set_child (ges_clip, "posy", (height - fh) / 2);
        }

        private static void _set_child (GES.Clip ges_clip, string name, int value) {
            GLib.Object child;
            GLib.ParamSpec pspec;
            if (!ges_clip.lookup_child (name, out child, out pspec)) return;
            var v = GLib.Value (pspec.value_type);
            if (pspec.value_type == typeof (int)) v.set_int (value);
            else if (pspec.value_type == typeof (double)) v.set_double (value);
            else if (pspec.value_type == typeof (float)) v.set_float (value);
            else return;
            ges_clip.set_child_property_by_pspec (pspec, v);
        }

        private string? _effect_description (EditList edl, EditClip clip) {
            string[] parts = {};
            if (edl.rotation != 0) parts += "videoflip method=%s".printf (Geometry.flip_method (edl.rotation));
            if (!edl.crop.is_identity () && clip.has_video) {
                int rw, rh;
                Geometry.rotated_size (clip.pixel_width (), clip.height, edl.rotation, out rw, out rh);
                int l, t, r, b;
                edl.crop.pixels (rw, rh, out l, out t, out r, out b);
                parts += "videocrop left=%d top=%d right=%d bottom=%d".printf (l, t, r, b);
            }
            if (parts.length == 0) return null;
            return string.joinv (" ! ", parts);
        }

        private Gst.PbUtils.EncodingProfile _profile (ExportFormat format, ExportPreset preset, EncoderSet encoders,
                                                      int width, int height, int fps_n, int fps_d) {
            string container_caps = format == ExportFormat.WEBM ? "video/webm" : "video/quicktime,variant=iso";
            string video_caps = format == ExportFormat.WEBM ? "video/x-vp9" : "video/x-h264";
            string audio_caps = format == ExportFormat.WEBM ? "audio/x-opus" : "audio/mpeg,mpegversion=4";
            var container = new Gst.PbUtils.EncodingContainerProfile ("videos", null,
                Gst.Caps.from_string (container_caps), null);
            var video = new Gst.PbUtils.EncodingVideoProfile (Gst.Caps.from_string (video_caps), null,
                Gst.Caps.from_string ("video/x-raw,width=%d,height=%d,framerate=%d/%d"
                    .printf (width, height, fps_n, fps_d)), 0);
            video.set_preset_name (encoders.video);
            var audio = new Gst.PbUtils.EncodingAudioProfile (Gst.Caps.from_string (audio_caps), null,
                Gst.Caps.from_string ("audio/x-raw,channels=2,rate=48000"), 0);
            audio.set_preset_name (encoders.audio);
            int kbps = preset.video_kbps (format, width, height);
            int akbps = format == ExportFormat.WEBM ? int.min (preset.audio_kbps (), 128) : preset.audio_kbps ();
            string? vprops = _video_properties (encoders.video, kbps, fps_n / int.max (1, fps_d), preset);
            if (vprops != null) {
                unowned string rest;
                var s = new Gst.Structure.from_string (vprops, out rest);
                if (s != null) video.set_element_properties ((owned) s);
            }
            unowned string arest;
            var aprops = new Gst.Structure.from_string ("element-properties, bitrate=%d".printf (akbps * 1000), out arest);
            if (aprops != null) audio.set_element_properties ((owned) aprops);
            container.add_profile (video);
            container.add_profile (audio);
            return container;
        }

        private string? _video_properties (string factory, int kbps, int fps, ExportPreset preset) {
            int gop = int.max (1, fps * 2);
            switch (factory) {
                case "x264enc":
                    return "element-properties, bitrate=(uint)%d, key-int-max=(uint)%d".printf (kbps, gop);
                case "openh264enc":
                    return "element-properties, bitrate=(uint)%d, gop-size=(uint)%d".printf (kbps * 1000, gop);
                case "vp9enc":
                    return "element-properties, target-bitrate=%d, deadline=(int64)1, cpu-used=%d, keyframe-max-dist=%d"
                        .printf (kbps * 1000, preset.vp9_cpu_used (), gop);
                default:
                    return null;
            }
        }

        private bool _on_message (Gst.Bus bus, Gst.Message msg) {
            if (msg.type == Gst.MessageType.EOS) {
                _stop ();
                finish_run (true, null);
                return GLib.Source.REMOVE;
            }
            if (msg.type == Gst.MessageType.ERROR) {
                GLib.Error err;
                string debug;
                msg.parse_error (out err, out debug);
                _stop ();
                finish_run (false, err.message);
                return GLib.Source.REMOVE;
            }
            return GLib.Source.CONTINUE;
        }

        private void _stop () {
            if (_poll_id != 0) {
                GLib.Source.remove (_poll_id);
                _poll_id = 0;
            }
            if (_watch_id != 0) {
                GLib.Source.remove (_watch_id);
                _watch_id = 0;
            }
            if (_pipeline != null) {
                _pipeline.set_state (Gst.State.NULL);
                _pipeline = null;
            }
        }
    }
}
