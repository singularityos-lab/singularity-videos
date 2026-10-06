using Singularity.Apps.Videos;

const int64 S = 1000000000;
const int64 MS = 1000000;

EditClip make_clip (string name, int64 duration, int w = 1920, int h = 1080) {
    var clip = new EditClip ("file:///videos/" + name, duration);
    clip.width = w;
    clip.height = h;
    clip.fps_n = 25;
    clip.fps_d = 1;
    return clip;
}

void assert_close (double a, double b, double eps = 1e-9) {
    if ((a - b).abs () > eps) {
        stderr.printf ("expected %f, got %f\n", b, a);
        assert_not_reached ();
    }
}

void test_trim () {
    var clip = make_clip ("a.mp4", 10 * S);
    assert (clip.kept_duration () == 10 * S);
    clip.set_trim (2 * S, 7 * S);
    assert (clip.in_point == 2 * S);
    assert (clip.out_point == 7 * S);
    assert (clip.kept_duration () == 5 * S);
    clip.set_trim (9 * S, 3 * S);
    assert (clip.in_point == 3 * S && clip.out_point == 9 * S);
    clip.set_trim (-5 * S, 50 * S);
    assert (clip.in_point == 0 && clip.out_point == 10 * S);
    clip.set_trim (2 * S, 7 * S);
    var edl = new EditList ();
    edl.add (clip);
    var segs = edl.segments ();
    assert (segs.length == 1);
    assert (segs[0].start == 2 * S && segs[0].end == 7 * S && segs[0].output_offset == 0);
    assert (edl.output_duration () == 5 * S);
    clip.reset_trim ();
    assert (clip.kept_duration () == 10 * S);
}

void test_cuts () {
    var clip = make_clip ("a.mp4", 10 * S);
    clip.set_trim (2 * S, 7 * S);
    clip.add_cut (3 * S, 4 * S);
    clip.add_cut (6 * S, 5 * S);
    var kept = clip.kept_ranges ();
    assert (kept.length == 3);
    assert (kept[0].start == 2 * S && kept[0].end == 3 * S);
    assert (kept[1].start == 4 * S && kept[1].end == 5 * S);
    assert (kept[2].start == 6 * S && kept[2].end == 7 * S);
    assert (clip.kept_duration () == 3 * S);
    assert (!clip.is_kept (3500 * MS));
    assert (clip.is_kept (4500 * MS));
    assert (clip.next_kept (3500 * MS) == 4 * S);
    assert (clip.next_kept (7 * S) == -1);

    clip.add_cut (3500 * MS, 5500 * MS);
    assert (clip.cuts ().length == 1);
    assert (clip.cuts ()[0].start == 3 * S && clip.cuts ()[0].end == 6 * S);
    assert (clip.kept_duration () == 2 * S);

    clip.add_cut (0, 1 * S);
    assert (clip.cuts ().length == 2);
    assert (clip.cuts ()[0].start == 0);
    assert (clip.kept_duration () == 2 * S);

    assert (clip.remove_cut_at (4 * S));
    assert (!clip.remove_cut_at (4 * S));
    assert (clip.cuts ().length == 1);
    assert (clip.kept_duration () == 5 * S);

    clip.add_cut (2 * S, 7 * S);
    assert (clip.kept_duration () == 0);
    var edl = new EditList ();
    edl.add (clip);
    assert (edl.segments ().length == 0);
    assert (edl.output_duration () == 0);
}

void test_join () {
    var edl = new EditList ();
    var a = make_clip ("a.mp4", 10 * S);
    var b = make_clip ("b.mp4", 4 * S);
    a.set_trim (1 * S, 6 * S);
    a.add_cut (2 * S, 3 * S);
    b.set_trim (500 * MS, 4 * S);
    edl.add (a);
    edl.add (b);
    assert (edl.size == 2);
    assert (edl.output_duration () == 7500 * MS);
    assert (edl.source_duration () == 14 * S);
    var segs = edl.segments ();
    assert (segs.length == 3);
    assert (segs[0].clip_index == 0 && segs[0].start == 1 * S && segs[0].end == 2 * S && segs[0].output_offset == 0);
    assert (segs[1].clip_index == 0 && segs[1].start == 3 * S && segs[1].end == 6 * S && segs[1].output_offset == 1 * S);
    assert (segs[2].clip_index == 1 && segs[2].start == 500 * MS && segs[2].output_offset == 4 * S);
    assert (segs[2].uri == "file:///videos/b.mp4");

    int64 local;
    assert (edl.clip_at (12 * S, out local) == 1 && local == 2 * S);
    assert (edl.clip_at (3 * S, out local) == 0 && local == 3 * S);
    assert (edl.clip_offset (1) == 10 * S);
    assert (edl.output_position (0, 4 * S) == 2 * S);
    assert (edl.output_position (1, 1 * S) == 4500 * MS);

    assert (edl.move (1, 0));
    assert (!edl.move (0, 0));
    assert (!edl.move (0, 5));
    segs = edl.segments ();
    assert (segs[0].clip_index == 0 && segs[0].uri == "file:///videos/b.mp4");
    assert (segs[0].output_offset == 0);
    assert (segs[1].output_offset == 3500 * MS);
    assert (edl.output_duration () == 7500 * MS);

    edl.remove_at (0);
    assert (edl.size == 1);
    assert (edl.output_duration () == 4 * S);
}

void test_frames () {
    var clip = make_clip ("a.mp4", 10 * S);
    assert (clip.frame_duration () == 40 * MS);
    assert (clip.snap (1019 * MS) == 1 * S);
    assert (clip.snap (1021 * MS) == 1040 * MS);
    assert (clip.snap (20 * S) == 10 * S);
    assert (clip.frame_at (1 * S) == 25);
    assert (clip.frame_at (1039 * MS) == 25);
    var ntsc = make_clip ("b.mp4", 10 * S);
    ntsc.fps_n = 30000;
    ntsc.fps_d = 1001;
    assert (ntsc.frame_at (ntsc.snap (1 * S)) == 30);
    assert (format_timecode (0) == "00:00:00.000");
    assert (format_timecode (3723 * S + 45 * MS) == "01:02:03.045");
    assert (format_timecode (-5) == "00:00:00.000");
}

void test_crop_rotate () {
    var box = new CropBox (0.1, 0.2, 0.3, 0.05);
    var r1 = box.rotated (1);
    assert_close (r1.left, 0.05);
    assert_close (r1.top, 0.1);
    assert_close (r1.right, 0.2);
    assert_close (r1.bottom, 0.3);
    var r4 = box.rotated (4);
    assert_close (r4.left, 0.1);
    assert_close (r4.bottom, 0.05);
    var back = box.rotated (1).rotated (-1);
    assert_close (back.top, 0.2);
    assert_close (back.right, 0.3);
    var r2 = box.rotated (2);
    assert_close (r2.left, 0.3);
    assert_close (r2.top, 0.05);

    var n = new CropBox (0.7, -1, 0.7, 0).normalized ();
    assert (n.width_fraction () >= CropBox.MIN_SIZE - 1e-9);
    assert (n.top == 0);

    int l, t, r, b;
    new CropBox (0.1, 0.1, 0.1, 0.1).pixels (1921, 1081, out l, out t, out r, out b);
    assert (l % 2 == 0 && t % 2 == 0 && r % 2 == 0 && b % 2 == 0);
    assert (l == 192 && t == 108);

    var sq = CropBox.with_aspect (1.0, 1920, 1080);
    assert_close (sq.left, (1920.0 - 1080.0) / 2.0 / 1920.0);
    assert_close (sq.top, 0);
    var tall = CropBox.with_aspect (9.0 / 16.0, 1920, 1080);
    assert_close (tall.width_fraction () * 1920 / 1080, 9.0 / 16.0, 1e-6);
    var wide = CropBox.with_aspect (21.0 / 9.0, 1920, 1080);
    assert_close (wide.left, 0);
    assert (wide.top > 0);

    int w, h;
    Geometry.rotated_size (1920, 1080, 1, out w, out h);
    assert (w == 1080 && h == 1920);
    Geometry.rotated_size (1920, 1080, 2, out w, out h);
    assert (w == 1920 && h == 1080);
    Geometry.rotated_size (1920, 1080, -1, out w, out h);
    assert (w == 1080 && h == 1920);
    Geometry.cropped_size (1920, 1080, 0, new CropBox (0.25, 0, 0.25, 0), out w, out h);
    assert (w == 960 && h == 1080);
    Geometry.cropped_size (1920, 1080, 1, new CropBox (0, 0.25, 0, 0.25), out w, out h);
    assert (w == 1080 && h == 960);
    assert (Geometry.flip_method (1) == "clockwise");
    assert (Geometry.flip_method (3) == "counterclockwise");
    assert (Geometry.flip_method (-1) == "counterclockwise");
    assert (Geometry.flip_method (2) == "rotate-180");
    assert (Geometry.flip_method (0) == "none");

    var edl = new EditList ();
    edl.add (make_clip ("a.mp4", 10 * S));
    edl.set_crop (new CropBox (0.1, 0.2, 0.3, 0.05));
    edl.rotate_by (1);
    assert (edl.rotation == 1);
    assert_close (edl.crop.left, 0.05);
    assert_close (edl.crop.top, 0.1);
    edl.rotate_by (-1);
    assert (edl.rotation == 0);
    assert_close (edl.crop.left, 0.1);
    edl.rotate_by (3);
    assert (edl.rotation == 3);
    assert_close (edl.crop.left, 0.2);
}

void test_output_geometry () {
    var edl = new EditList ();
    edl.add (make_clip ("a.mp4", 10 * S));
    int w, h;
    edl.output_size (new ExportPreset (ExportQuality.HIGH), out w, out h);
    assert (w == 1920 && h == 1080);
    edl.output_size (new ExportPreset (ExportQuality.MEDIUM), out w, out h);
    assert (w == 1280 && h == 720);
    edl.output_size (new ExportPreset (ExportQuality.SMALL), out w, out h);
    assert (w == 854 && h == 480);
    edl.set_rotation (1);
    edl.output_size (new ExportPreset (ExportQuality.MEDIUM), out w, out h);
    assert (w == 720 && h == 1280);
    edl.set_rotation (0);
    edl.set_crop (new CropBox (0.21875, 0, 0.21875, 0));
    edl.output_size (new ExportPreset (ExportQuality.MEDIUM), out w, out h);
    assert (w == 720 && h == 720);

    var small = new EditList ();
    small.add (make_clip ("s.mp4", 1 * S, 640, 360));
    small.output_size (new ExportPreset (ExportQuality.HIGH), out w, out h);
    assert (w == 640 && h == 360);
    var odd = new EditList ();
    odd.add (make_clip ("o.mp4", 1 * S, 321, 241));
    odd.output_size (new ExportPreset (ExportQuality.HIGH), out w, out h);
    assert (w % 2 == 0 && h % 2 == 0);

    var audio_only = new EditList ();
    var ac = make_clip ("a.ogg", 1 * S, 0, 0);
    ac.has_video = false;
    audio_only.add (ac);
    audio_only.output_size (new ExportPreset (ExportQuality.MEDIUM), out w, out h);
    assert (w == 1280 && h == 720);

    int fn, fd;
    edl.output_framerate (out fn, out fd);
    assert (fn == 25 && fd == 1);
    var fast = new EditList ();
    var fc = make_clip ("f.mp4", 1 * S);
    fc.fps_n = 120;
    fast.add (fc);
    fast.output_framerate (out fn, out fd);
    assert (fn == 60 && fd == 1);
}

void test_presets () {
    var high = new ExportPreset (ExportQuality.HIGH);
    var medium = new ExportPreset (ExportQuality.MEDIUM);
    var small = new ExportPreset (ExportQuality.SMALL);
    assert (high.max_long_side () == 1920 && high.max_short_side () == 1080);
    assert (medium.max_long_side () == 1280 && medium.max_short_side () == 720);
    assert (small.max_long_side () == 854 && small.max_short_side () == 480);
    assert (high.video_kbps (ExportFormat.MP4, 1920, 1080) == 8087);
    assert (medium.video_kbps (ExportFormat.MP4, 1280, 720) == 2765);
    assert (medium.video_kbps (ExportFormat.WEBM, 1280, 720) == 1935);
    assert (small.video_kbps (ExportFormat.MP4, 854, 480) == 984);
    assert (small.video_kbps (ExportFormat.MP4, 16, 16) == 200);
    assert (high.video_kbps (ExportFormat.MP4, 720, 720) > medium.video_kbps (ExportFormat.MP4, 720, 720));
    assert (medium.video_kbps (ExportFormat.MP4, 720, 720) > small.video_kbps (ExportFormat.MP4, 720, 720));
    assert (high.audio_kbps () > medium.audio_kbps () && medium.audio_kbps () > small.audio_kbps ());
    assert (medium.estimated_bytes (ExportFormat.MP4, 1280, 720, 8 * S) == (int64) ((2765 + 128) * 1000.0 * 8 / 8));
    assert (ExportFormat.parse ("WebM") == ExportFormat.WEBM);
    assert (ExportFormat.parse ("mkv") == null);
    assert (ExportFormat.MP4.extension () == "mp4");
    assert (ExportQuality.parse ("small") == ExportQuality.SMALL);
    assert (high.vp9_cpu_used () < small.vp9_cpu_used ());
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/trim/trim", test_trim);
    Test.add_func ("/trim/cuts", test_cuts);
    Test.add_func ("/trim/join", test_join);
    Test.add_func ("/trim/frames", test_frames);
    Test.add_func ("/trim/crop-rotate", test_crop_rotate);
    Test.add_func ("/trim/output-geometry", test_output_geometry);
    Test.add_func ("/trim/presets", test_presets);
    return Test.run ();
}
