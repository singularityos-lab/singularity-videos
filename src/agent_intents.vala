namespace Singularity.Apps.Videos {

    internal class VideosIntents : Object {
        private const string[] CONTROLS = { "play", "pause", "toggle", "stop", "seek", "skip" };
        private const int DEFAULT_LIMIT = 20;

        private static string text (Json.Object args, string key) {
            return args.has_member (key) ? args.get_string_member (key) : "";
        }

        private static Json.Node obj (Json.Object o) {
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (o);
            return node;
        }

        private static string list (string[] values) {
            var b = new StringBuilder ("[");
            for (int i = 0; i < values.length; i++) {
                if (i > 0) b.append (",");
                b.append ("\"").append (values[i]).append ("\"");
            }
            return b.append ("]").str;
        }

        private static double seconds (int64 ns) {
            return ns <= 0 ? 0.0 : Math.round (ns / 100000000.0) / 10.0;
        }

        private static Json.Array names (string[] values) {
            var a = new Json.Array ();
            foreach (var v in values) a.add_string_element (v);
            return a;
        }

        private static Json.Node status (PlayerWindow w) {
            var o = new Json.Object ();
            bool loaded = w.mpris_loaded;
            o.set_boolean_member ("loaded", loaded);
            if (loaded) {
                string uri = w.mpris_uri;
                string title = w.mpris_title;
                if (title == "" && uri != "") {
                    string name = File.new_for_uri (uri).get_basename () ?? uri;
                    int dot = name.last_index_of_char ('.');
                    title = dot > 0 ? name.substring (0, dot) : name;
                }
                o.set_string_member ("uri", uri);
                o.set_string_member ("title", title);
                o.set_boolean_member ("playing", w.mpris_playing);
                o.set_double_member ("position", seconds (w.mpris_position));
                o.set_double_member ("duration", seconds (w.mpris_duration));
            }
            var p = w.player;
            o.set_double_member ("volume", Math.round (p.volume * 100) / 100.0);
            o.set_boolean_member ("muted", p.muted);
            o.set_double_member ("rate", p.rate);
            o.set_boolean_member ("fullscreen", w.fullscreened);
            if (loaded && w.on_player) {
                o.set_array_member ("audio_tracks", names (p.audio_tracks ()));
                o.set_int_member ("audio_track", p.current_audio);
                o.set_array_member ("subtitle_tracks", names (p.subtitle_tracks ()));
                o.set_int_member ("subtitle_track", p.current_subtitle);
            }
            return obj (o);
        }

        private static string target (Json.Object args) throws Error {
            string path = text (args, "path");
            string url = text (args, "url");
            if (path != "") {
                if (!FileUtils.test (path, FileTest.IS_REGULAR)) throw new IOError.NOT_FOUND ("%s does not exist", path);
                return File.new_for_path (path).get_uri ();
            }
            if (url != "") {
                string? scheme = Uri.peek_scheme (url);
                if (scheme != "http" && scheme != "https" && scheme != "file") throw new IOError.INVALID_ARGUMENT ("only http, https and file addresses can be opened");
                return url;
            }
            throw new IOError.INVALID_ARGUMENT ("give a path or a url");
        }

        private static void need_loaded (PlayerWindow w) throws Error {
            if (!w.mpris_loaded) throw new IOError.FAILED ("no video is open");
        }

        internal static void install (VideosApp app) {
            var agent = app.agent;
            agent.add_intent ("videos_status", "Read the open video: title, address, playing state, position, duration, volume, speed, fullscreen, and its audio and subtitle tracks.",
                "{\"type\":\"object\",\"properties\":{}}",
                Singularity.AppIntentRisk.READ, (args) => status (app.ensure_window ()));

            agent.add_intent ("videos_open", "Open and play a video file by path or a video address (http, https). Resumes from where it was left when the history has it.",
                "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"url\":{\"type\":\"string\"}}}",
                Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    string uri = target (args);
                    var w = app.ensure_window ();
                    w.open_uri (uri);
                    return status (w);
                });

            agent.add_intent ("videos_control", "Control playback: play, pause, toggle, stop, seek to a position in seconds, or skip forward or back by seconds.",
                "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\",\"enum\":" + list (CONTROLS) + "},\"seconds\":{\"type\":\"number\"}},\"required\":[\"action\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    string action = text (args, "action");
                    if (!(action in CONTROLS)) throw new IOError.INVALID_ARGUMENT ("unknown action %s", action);
                    var w = app.ensure_window ();
                    need_loaded (w);
                    switch (action) {
                        case "play": w.mpris_set_playing (true); break;
                        case "pause": w.mpris_set_playing (false); break;
                        case "toggle": w.mpris_set_playing (!w.mpris_playing); break;
                        case "stop": w.mpris_stop (); break;
                        default:
                            if (!args.has_member ("seconds")) throw new IOError.INVALID_ARGUMENT ("%s needs seconds", action);
                            int64 ns = (int64) (args.get_double_member ("seconds") * 1000000000.0);
                            if (action == "skip") ns += w.mpris_position;
                            int64 dur = w.mpris_duration;
                            if (dur > 0) ns = int64.min (ns, dur);
                            w.mpris_seek_to (int64.max (0, ns));
                            break;
                    }
                    return status (w);
                });

            agent.add_intent ("videos_settings", "Change the volume from 0 to 1, mute, playback speed from 0.25 to 4, fullscreen, the audio track, or the subtitle track (-1 turns subtitles off).",
                "{\"type\":\"object\",\"properties\":{\"volume\":{\"type\":\"number\"},\"muted\":{\"type\":\"boolean\"},\"rate\":{\"type\":\"number\"},\"fullscreen\":{\"type\":\"boolean\"},\"audio_track\":{\"type\":\"integer\"},\"subtitle_track\":{\"type\":\"integer\"}}}",
                Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    var w = app.ensure_window ();
                    var p = w.player;
                    if (args.has_member ("audio_track")) {
                        need_loaded (w);
                        int i = (int) args.get_int_member ("audio_track");
                        if (i < 0 || i >= p.audio_tracks ().length) throw new IOError.NOT_FOUND ("the video has no audio track %d", i);
                        w.activate_action ("audio-track", new Variant.int32 (i));
                    }
                    if (args.has_member ("subtitle_track")) {
                        need_loaded (w);
                        int i = (int) args.get_int_member ("subtitle_track");
                        if (i < -1 || i >= p.subtitle_tracks ().length) throw new IOError.NOT_FOUND ("the video has no subtitle track %d", i);
                        w.activate_action ("subtitle", new Variant.int32 (i));
                    }
                    if (args.has_member ("rate")) {
                        double r = args.get_double_member ("rate");
                        if (r < 0.25 || r > 4.0) throw new IOError.INVALID_ARGUMENT ("the speed must be between 0.25 and 4");
                        w.activate_action ("rate", new Variant.double (r));
                    }
                    if (args.has_member ("volume")) w.set_volume_level (args.get_double_member ("volume"));
                    if (args.has_member ("muted")) w.set_muted (args.get_boolean_member ("muted"));
                    if (args.has_member ("fullscreen")) {
                        if (args.get_boolean_member ("fullscreen")) w.fullscreen ();
                        else w.unfullscreen ();
                    }
                    return status (w);
                });

            agent.add_intent ("videos_history", "List the videos watched recently, newest first, with where playback stopped.",
                "{\"type\":\"object\",\"properties\":{\"limit\":{\"type\":\"integer\"}}}",
                Singularity.AppIntentRisk.READ, (args) => {
                    int limit = args.has_member ("limit") ? (int) args.get_int_member ("limit").clamp (1, 200) : DEFAULT_LIMIT;
                    var w = app.ensure_window ();
                    var a = new Json.Array ();
                    foreach (var e in w.history.recent (limit)) {
                        var eo = new Json.Object ();
                        eo.set_string_member ("title", e.title);
                        eo.set_string_member ("uri", e.uri);
                        eo.set_double_member ("position", seconds (e.position));
                        eo.set_double_member ("duration", seconds (e.duration));
                        eo.set_boolean_member ("resumable", e.resumable);
                        a.add_object_element (eo);
                    }
                    var o = new Json.Object ();
                    o.set_boolean_member ("enabled", VideoHistory.enabled ());
                    o.set_array_member ("videos", a);
                    return obj (o);
                });
        }
    }
}
