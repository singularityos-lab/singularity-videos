using Singularity.Apps.Videos;

const int64 S = 1000000000;
const int64 MS = 1000000;
const int64 TOLERANCE = 150 * MS;

string workdir;
string clip_a;
string clip_b;
string clip_c;
string? backend_choice = null;

bool render (string description, string path) {
    try {
        var pipeline = Gst.parse_launch (description.printf (path));
        pipeline.set_state (Gst.State.PLAYING);
        var msg = pipeline.get_bus ().timed_pop_filtered (60 * Gst.SECOND,
            Gst.MessageType.EOS | Gst.MessageType.ERROR);
        pipeline.set_state (Gst.State.NULL);
        return msg != null && msg.type == Gst.MessageType.EOS;
    } catch (GLib.Error e) {
        stderr.printf ("fixture: %s\n", e.message);
        return false;
    }
}

bool make_fixtures () {
    workdir = GLib.Environment.get_variable ("VIDEOS_TEST_DIR") ?? "";
    if (workdir == "") {
        try {
            workdir = GLib.DirUtils.make_tmp ("videos-trim-XXXXXX");
        } catch (GLib.Error e) {
            return false;
        }
    }
    GLib.DirUtils.create_with_parents (workdir, 0755);
    clip_a = GLib.Path.build_filename (workdir, "a.mp4");
    clip_b = GLib.Path.build_filename (workdir, "b.mp4");
    clip_c = GLib.Path.build_filename (workdir, "c.mp4");
    string video = "videotestsrc num-buffers=%d pattern=%s ! video/x-raw,format=I420,width=%d,height=%d,framerate=%d/1 ! x264enc ! mp4mux name=mux ! filesink location=%%s ";
    string audio = "audiotestsrc num-buffers=%d samplesperbuffer=1000 freq=%d ! audio/x-raw,rate=48000,channels=2 ! voaacenc ! mux.";
    return render ((video + audio).printf (100, "smpte", 640, 360, 25, 192, 440), clip_a)
        && render ((video + audio).printf (90, "ball", 320, 240, 30, 144, 880), clip_b)
        && render (video.printf (50, "snow", 640, 360, 25), clip_c);
}

string uri (string path) {
    return GLib.File.new_for_path (path).get_uri ();
}

EditClip probe (string path) {
    string? error;
    var clip = MediaProbe.probe_sync (uri (path), out error);
    if (clip == null) {
        stderr.printf ("probe %s: %s\n", path, error ?? "");
        assert_not_reached ();
    }
    return clip;
}

bool export (EditList edl, ExportFormat format, ExportQuality quality, string out_path, int cancel_ms = -1) {
    var exporter = ExportBackends.create (backend_choice);
    var loop = new GLib.MainLoop ();
    bool result = false;
    double last_progress = 0;
    exporter.progress.connect ((f) => last_progress = f);
    exporter.finished.connect ((ok, error) => {
        if (!ok && error != null) stderr.printf ("export failed: %s\n", error);
        result = ok;
        loop.quit ();
    });
    if (cancel_ms >= 0) {
        GLib.Timeout.add (cancel_ms, () => {
            exporter.cancel ();
            return GLib.Source.REMOVE;
        });
    }
    GLib.Timeout.add_seconds (300, () => {
        exporter.cancel ();
        return GLib.Source.REMOVE;
    });
    exporter.start (edl, format, new ExportPreset (quality), out_path);
    loop.run ();
    if (result) assert (last_progress >= 0.99);
    return result;
}

struct Streams {
    int64 duration;
    string video;
    string audio;
    int width;
    int height;
}

Streams discover (string path) {
    var s = Streams ();
    s.video = "";
    s.audio = "";
    try {
        var d = new Gst.PbUtils.Discoverer (30 * Gst.SECOND);
        var info = d.discover_uri (uri (path));
        s.duration = (int64) info.get_duration ();
        foreach (var v in info.get_video_streams ()) {
            var vi = (Gst.PbUtils.DiscovererVideoInfo) v;
            s.video = vi.get_caps ().get_structure (0).get_name ();
            s.width = (int) vi.get_width ();
            s.height = (int) vi.get_height ();
        }
        foreach (var a in info.get_audio_streams ())
            s.audio = a.get_caps ().get_structure (0).get_name ();
    } catch (GLib.Error e) {
        stderr.printf ("discover %s: %s\n", path, e.message);
        assert_not_reached ();
    }
    stdout.printf ("# %s: %.3fs %s %dx%d %s\n", GLib.Path.get_basename (path),
                   (double) s.duration / S, s.video, s.width, s.height, s.audio);
    return s;
}

void check (Streams s, int64 duration, string video, string audio, int width, int height) {
    if ((s.duration - duration).abs () > TOLERANCE) {
        stderr.printf ("duration %lld, expected %lld\n", s.duration, duration);
        assert_not_reached ();
    }
    assert (s.video == video);
    assert (s.audio == audio);
    assert (s.width == width && s.height == height);
}

string out_file (string name) {
    string prefix = backend_choice ?? "auto";
    return GLib.Path.build_filename (workdir, prefix + "-" + name);
}

void test_trim () {
    var edl = new EditList ();
    var a = probe (clip_a);
    assert (a.fps_n == 25 && a.width == 640 && a.has_audio);
    a.set_trim (1 * S, 3 * S);
    edl.add (a);
    string path = out_file ("trim.mp4");
    assert (export (edl, ExportFormat.MP4, ExportQuality.MEDIUM, path));
    check (discover (path), 2 * S, "video/x-h264", "audio/mpeg", 640, 360);
}

void test_cut () {
    var edl = new EditList ();
    var a = probe (clip_a);
    a.add_cut (1 * S, 1500 * MS);
    a.add_cut (2500 * MS, 3 * S);
    edl.add (a);
    assert (edl.output_duration () == 3 * S);
    string path = out_file ("cut.mp4");
    assert (export (edl, ExportFormat.MP4, ExportQuality.SMALL, path));
    check (discover (path), 3 * S, "video/x-h264", "audio/mpeg", 640, 360);
}

void test_join () {
    var edl = new EditList ();
    var a = probe (clip_a);
    a.set_trim (0, 2 * S);
    var b = probe (clip_b);
    var c = probe (clip_c);
    assert (!c.has_audio);
    edl.add (a);
    edl.add (b);
    edl.add (c);
    edl.move (2, 1);
    assert (edl.output_duration () == 7 * S);
    string path = out_file ("join.mp4");
    assert (export (edl, ExportFormat.MP4, ExportQuality.HIGH, path));
    check (discover (path), 7 * S, "video/x-h264", "audio/mpeg", 640, 360);
}

void test_crop_rotate () {
    var edl = new EditList ();
    var a = probe (clip_a);
    a.set_trim (0, 2 * S);
    edl.add (a);
    edl.set_rotation (1);
    edl.set_crop (CropBox.with_aspect (1.0, 360, 640));
    string path = out_file ("croprotate.mp4");
    assert (export (edl, ExportFormat.MP4, ExportQuality.MEDIUM, path));
    check (discover (path), 2 * S, "video/x-h264", "audio/mpeg", 360, 360);

    var edl2 = new EditList ();
    var a2 = probe (clip_a);
    a2.set_trim (0, 1 * S);
    edl2.add (a2);
    edl2.set_rotation (1);
    string path2 = out_file ("rotate.mp4");
    assert (export (edl2, ExportFormat.MP4, ExportQuality.MEDIUM, path2));
    check (discover (path2), 1 * S, "video/x-h264", "audio/mpeg", 360, 640);
}

void test_webm () {
    if (!Encoders.available (ExportFormat.WEBM)) {
        Test.skip ("VP9 or Opus encoder missing");
        return;
    }
    var edl = new EditList ();
    var a = probe (clip_a);
    a.set_trim (500 * MS, 2500 * MS);
    edl.add (a);
    string path = out_file ("web.webm");
    assert (export (edl, ExportFormat.WEBM, ExportQuality.SMALL, path));
    check (discover (path), 2 * S, "video/x-vp9", "audio/x-opus", 640, 360);
}

void test_cancel () {
    var edl = new EditList ();
    edl.add (probe (clip_a));
    edl.add (probe (clip_b));
    string path = out_file ("cancel.mp4");
    assert (!export (edl, ExportFormat.MP4, ExportQuality.HIGH, path, 150));
    assert (!GLib.FileUtils.test (path, GLib.FileTest.EXISTS));
}

int main (string[] args) {
    Test.init (ref args);
    Gst.init (ref args);
    if (!Encoders.available (ExportFormat.MP4) || !Encoders.has_element ("x264enc")
        || !Encoders.has_element ("voaacenc") || !Encoders.has_element ("videotestsrc")) {
        stdout.printf ("1..0 # SKIP H.264 or AAC encoders missing\n");
        return 77;
    }
    backend_choice = GLib.Environment.get_variable ("VIDEOS_TEST_BACKEND");
    if (!make_fixtures ()) {
        stderr.printf ("could not generate fixtures\n");
        return 1;
    }
    Test.add_func ("/export/trim", test_trim);
    Test.add_func ("/export/cut", test_cut);
    Test.add_func ("/export/join", test_join);
    Test.add_func ("/export/crop-rotate", test_crop_rotate);
    Test.add_func ("/export/webm", test_webm);
    Test.add_func ("/export/cancel", test_cancel);
    return Test.run ();
}
