namespace Singularity.Apps.Videos {

    public enum ExportFormat {
        MP4,
        WEBM;

        public string extension () {
            return this == WEBM ? "webm" : "mp4";
        }

        public string label () {
            return this == WEBM ? _("WebM") : _("MP4");
        }

        public string codecs () {
            return this == WEBM ? _("VP9 video and Opus audio") : _("H.264 video and AAC audio");
        }

        public string mime_type () {
            return this == WEBM ? "video/webm" : "video/mp4";
        }

        public static ExportFormat? parse (string name) {
            switch (name.down ()) {
                case "mp4": return MP4;
                case "webm": return WEBM;
                default: return null;
            }
        }
    }

    public enum ExportQuality {
        HIGH,
        MEDIUM,
        SMALL;

        public static ExportQuality? parse (string name) {
            switch (name.down ()) {
                case "high": return HIGH;
                case "medium": return MEDIUM;
                case "small": return SMALL;
                default: return null;
            }
        }
    }

    public class ExportPreset : GLib.Object {
        public ExportQuality quality { get; construct; }

        public ExportPreset (ExportQuality quality) {
            GLib.Object (quality: quality);
        }

        public string label () {
            switch (quality) {
                case ExportQuality.HIGH: return _("High");
                case ExportQuality.SMALL: return _("Small");
                default: return _("Medium");
            }
        }

        public string summary () {
            switch (quality) {
                case ExportQuality.HIGH: return _("Up to 1080p for large screens");
                case ExportQuality.SMALL: return _("Up to 480p, quick to share");
                default: return _("Up to 720p for the web");
            }
        }

        public int max_long_side () {
            switch (quality) {
                case ExportQuality.HIGH: return 1920;
                case ExportQuality.SMALL: return 854;
                default: return 1280;
            }
        }

        public int max_short_side () {
            switch (quality) {
                case ExportQuality.HIGH: return 1080;
                case ExportQuality.SMALL: return 480;
                default: return 720;
            }
        }

        public double bits_per_pixel () {
            switch (quality) {
                case ExportQuality.HIGH: return 0.13;
                case ExportQuality.SMALL: return 0.08;
                default: return 0.10;
            }
        }

        public int audio_kbps () {
            switch (quality) {
                case ExportQuality.HIGH: return 192;
                case ExportQuality.SMALL: return 96;
                default: return 128;
            }
        }

        public int video_kbps (ExportFormat format, int width, int height) {
            double kbps = (double) width * height * 30 * bits_per_pixel () / 1000.0;
            if (format == ExportFormat.WEBM) kbps *= 0.7;
            return int.max (200, (int) Math.round (kbps));
        }

        public int64 estimated_bytes (ExportFormat format, int width, int height, int64 duration) {
            double seconds = (double) duration / NS_PER_SECOND;
            int audio = format == ExportFormat.WEBM ? int.min (audio_kbps (), 128) : audio_kbps ();
            double bits = (video_kbps (format, width, height) + audio) * 1000.0 * seconds;
            return (int64) (bits / 8.0);
        }

        public int vp9_cpu_used () {
            switch (quality) {
                case ExportQuality.HIGH: return 2;
                case ExportQuality.SMALL: return 6;
                default: return 4;
            }
        }
    }

    public class EncoderSet : GLib.Object {
        public string? video { get; construct; }
        public string? audio { get; construct; }
        public string? muxer { get; construct; }
        public string? parser { get; construct; }

        public EncoderSet (string? video, string? audio, string? muxer, string? parser) {
            GLib.Object (video: video, audio: audio, muxer: muxer, parser: parser);
        }

        public bool complete () {
            return video != null && audio != null && muxer != null;
        }
    }

    public class ExportConfig : GLib.Object {

        public const string FILE_NAME = "videos-export.conf";

        private static ExportConfig? _instance = null;
        private GLib.KeyFile? _file = null;

        public static ExportConfig get_default () {
            if (_instance == null) _instance = new ExportConfig ();
            return _instance;
        }

        construct {
            string[] dirs = {};
            string? custom = GLib.Environment.get_variable ("SINGULARITY_VIDEOS_EXPORT_CONF");
            if (custom != null && custom != "") dirs += custom;
            dirs += GLib.Path.build_filename (GLib.Environment.get_user_config_dir (), "singularity", FILE_NAME);
            foreach (unowned string d in GLib.Environment.get_system_config_dirs ())
                dirs += GLib.Path.build_filename (d, "singularity", FILE_NAME);
            foreach (var path in dirs) {
                if (!GLib.FileUtils.test (path, GLib.FileTest.IS_REGULAR)) continue;
                var kf = new GLib.KeyFile ();
                try {
                    kf.load_from_file (path, GLib.KeyFileFlags.NONE);
                    _file = kf;
                    break;
                } catch (GLib.Error e) {
                    warning ("videos: cannot read %s: %s", path, e.message);
                }
            }
        }

        public string backend () {
            string? env = GLib.Environment.get_variable ("SINGULARITY_VIDEOS_EXPORT_BACKEND");
            if (env != null && env != "") return env;
            return _string ("Export", "backend") ?? "auto";
        }

        public string[] candidates (string key, string[] defaults) {
            string? value = _string ("Encoders", key);
            if (value == null || value.strip () == "") return defaults;
            string[] names = {};
            foreach (var part in value.split (";")) {
                string n = part.strip ();
                if (n != "") names += n;
            }
            return names.length > 0 ? names : defaults;
        }

        private string? _string (string group, string key) {
            if (_file == null) return null;
            try {
                return _file.get_string (group, key);
            } catch (GLib.Error e) {
                return null;
            }
        }
    }

    namespace Encoders {

        public bool has_element (string name) {
            var factory = Gst.ElementFactory.find (name);
            return factory != null;
        }

        public string? first_available (string[] names) {
            foreach (var n in names) {
                if (has_element (n)) return n;
            }
            return null;
        }

        public EncoderSet resolve (ExportFormat format) {
            var config = ExportConfig.get_default ();
            if (format == ExportFormat.WEBM) {
                return new EncoderSet (
                    first_available (config.candidates ("vp9", { "vp9enc" })),
                    first_available (config.candidates ("opus", { "opusenc" })),
                    first_available (config.candidates ("webm-muxer", { "webmmux" })),
                    null);
            }
            return new EncoderSet (
                first_available (config.candidates ("h264", { "x264enc", "openh264enc" })),
                first_available (config.candidates ("aac", { "fdkaacenc", "voaacenc", "avenc_aac" })),
                first_available (config.candidates ("mp4-muxer", { "mp4mux", "qtmux" })),
                first_available ({ "h264parse" }));
        }

        public bool available (ExportFormat format) {
            return resolve (format).complete ();
        }

        public void configure_video (Gst.Element enc, ExportFormat format, ExportPreset preset,
                                     int width, int height, int fps) {
            int kbps = preset.video_kbps (format, width, height);
            string name = enc.get_factory ().get_name ();
            int gop = int.max (1, fps * 2);
            switch (name) {
                case "x264enc":
                    set_prop (enc, "bitrate", kbps.to_string ());
                    set_prop (enc, "speed-preset", preset.quality == ExportQuality.HIGH ? "medium" : "faster");
                    set_prop (enc, "key-int-max", gop.to_string ());
                    break;
                case "openh264enc":
                    set_prop (enc, "bitrate", (kbps * 1000).to_string ());
                    set_prop (enc, "gop-size", gop.to_string ());
                    set_prop (enc, "rate-control", "bitrate");
                    break;
                case "vp9enc":
                    set_prop (enc, "target-bitrate", (kbps * 1000).to_string ());
                    set_prop (enc, "end-usage", "vbr");
                    set_prop (enc, "deadline", "1");
                    set_prop (enc, "cpu-used", preset.vp9_cpu_used ().to_string ());
                    set_prop (enc, "row-mt", "true");
                    set_prop (enc, "threads", int.max (1, (int) GLib.get_num_processors ()).to_string ());
                    set_prop (enc, "keyframe-max-dist", gop.to_string ());
                    break;
                default:
                    if (!set_prop (enc, "bitrate", kbps.to_string ()))
                        set_prop (enc, "target-bitrate", (kbps * 1000).to_string ());
                    break;
            }
        }

        public void configure_audio (Gst.Element enc, ExportFormat format, ExportPreset preset) {
            int kbps = preset.audio_kbps ();
            if (format == ExportFormat.WEBM) kbps = int.min (kbps, 128);
            string name = enc.get_factory ().get_name ();
            if (name == "avenc_aac") set_prop (enc, "compliance", "-2");
            set_prop (enc, "bitrate", (kbps * 1000).to_string ());
        }

        public void configure_muxer (Gst.Element mux) {
            set_prop (mux, "faststart", "true");
        }

        public bool set_prop (Gst.Element element, string name, string value) {
            if (element.get_class ().find_property (name) == null) return false;
            Gst.Util.set_object_arg (element, name, value);
            return true;
        }
    }
}
