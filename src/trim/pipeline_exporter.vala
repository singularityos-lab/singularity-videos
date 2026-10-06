namespace Singularity.Apps.Videos {

    public class PipelineExporter : ExportBackend {

        private const int RATE = 48000;
        private const int CHANNELS = 2;
        private const int BYTES_PER_FRAME = 4;

        public override string backend_id {
            get { return "pipeline"; }
        }

        private EditList _edl;
        private ExportFormat _format;
        private ExportPreset _preset;
        private int _width;
        private int _height;
        private int _fps_n;
        private int _fps_d;
        private int64 _total;
        private int _cancelled = 0;

        private Gst.Pipeline? _encode = null;
        private Gst.App.Src? _vsrc = null;
        private Gst.App.Src? _asrc = null;

        private int64 _offset = 0;
        private int64 _seg_len = 0;
        private int64 _video_end = 0;
        private int64 _audio_end = 0;
        private Gst.Buffer? _last_frame = null;
        private GLib.Mutex _lock = GLib.Mutex ();

        public override void start (EditList edl, ExportFormat format, ExportPreset preset, string output_path) {
            _edl = edl;
            _format = format;
            _preset = preset;
            edl.output_size (preset, out _width, out _height);
            edl.output_framerate (out _fps_n, out _fps_d);
            _total = edl.output_duration ();
            GLib.AtomicInt.set (ref _cancelled, 0);
            begin_run (output_path);
            var segments = edl.segments ();
            EditClip[] clips = {};
            for (int i = 0; i < edl.size; i++) clips += edl.get_clip (i);
            string path = output_path;
            new GLib.Thread<bool> ("videos-export", () => {
                string? error = null;
                bool ok = _run (segments, clips, path, out error);
                finish_run (ok, error);
                return ok;
            });
        }

        public override void cancel () {
            GLib.AtomicInt.set (ref _cancelled, 1);
        }

        private bool _is_cancelled () {
            return GLib.AtomicInt.get (ref _cancelled) != 0;
        }

        private bool _run (Segment[] segments, EditClip[] clips, string path, out string? error) {
            error = null;
            if (segments.length == 0 || _total <= 0) {
                error = _("Nothing is left to export.");
                return false;
            }
            var encoders = Encoders.resolve (_format);
            if (!encoders.complete ()) {
                error = _("The encoders for %s are not installed.").printf (_format.label ());
                return false;
            }
            if (!_build_encoder (encoders, path, out error)) {
                _teardown ();
                return false;
            }
            _offset = 0;
            foreach (var seg in segments) {
                if (_is_cancelled ()) break;
                if (!_run_segment (seg, clips[seg.clip_index], out error)) {
                    _teardown ();
                    return false;
                }
                _offset += seg.length ();
            }
            if (_is_cancelled ()) {
                _teardown ();
                return false;
            }
            _vsrc.end_of_stream ();
            _asrc.end_of_stream ();
            bool ok = _wait_encoder (out error);
            _teardown ();
            return ok;
        }

        private Gst.Element? _make (string factory) {
            return Gst.ElementFactory.make (factory, null);
        }

        private bool _build_encoder (EncoderSet encoders, string path, out string? error) {
            error = null;
            _encode = new Gst.Pipeline ("videos-export");
            _vsrc = (Gst.App.Src) _make ("appsrc");
            _asrc = (Gst.App.Src) _make ("appsrc");
            var vq = _make ("queue");
            var aq = _make ("queue");
            var vconv = _make ("videoconvert");
            var aconv = _make ("audioconvert");
            var ares = _make ("audioresample");
            var venc = _make (encoders.video);
            var aenc = _make (encoders.audio);
            var mux = _make (encoders.muxer);
            var sink = _make ("filesink");
            Gst.Element? parser = encoders.parser != null ? _make (encoders.parser) : null;
            if (_vsrc == null || _asrc == null || vq == null || aq == null || vconv == null || aconv == null
                || ares == null || venc == null || aenc == null || mux == null || sink == null) {
                error = _("A required GStreamer element is missing.");
                return false;
            }
            _vsrc.caps = Gst.Caps.from_string ("video/x-raw,format=I420,width=%d,height=%d,framerate=%d/%d,pixel-aspect-ratio=1/1"
                .printf (_width, _height, _fps_n, _fps_d));
            _asrc.caps = Gst.Caps.from_string ("audio/x-raw,format=S16LE,layout=interleaved,rate=%d,channels=%d,channel-mask=(bitmask)0x3"
                .printf (RATE, CHANNELS));
            foreach (var src in new Gst.App.Src[] { _vsrc, _asrc }) {
                src.format = Gst.Format.TIME;
                src.block = true;
                src.is_live = false;
            }
            _vsrc.max_bytes = (uint64) _width * _height * 3 / 2 * 8;
            _asrc.max_bytes = RATE * BYTES_PER_FRAME;
            foreach (var q in new Gst.Element[] { vq, aq }) {
                q.set ("max-size-buffers", 0u);
                q.set ("max-size-bytes", 0u);
                q.set ("max-size-time", (uint64) (8 * Gst.SECOND));
            }
            Encoders.configure_video (venc, _format, _preset, _width, _height,
                                      (int) Math.round ((double) _fps_n / _fps_d));
            Encoders.configure_audio (aenc, _format, _preset);
            Encoders.configure_muxer (mux);
            sink.set ("location", path);
            _encode.add_many (_vsrc, vq, vconv, venc, _asrc, aq, aconv, ares, aenc, mux, sink);
            if (parser != null) _encode.add (parser);
            bool linked = _vsrc.link_many (vq, vconv, venc)
                && (parser != null ? venc.link (parser) && parser.link (mux) : venc.link (mux))
                && _asrc.link_many (aq, aconv, ares, aenc)
                && aenc.link (mux)
                && mux.link (sink);
            if (!linked) {
                error = _("The export pipeline could not be built.");
                return false;
            }
            if (_encode.set_state (Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE) {
                error = _("The encoder could not start.");
                return false;
            }
            return true;
        }

        private bool _run_segment (Segment seg, EditClip clip, out string? error) {
            error = null;
            var dec = new Gst.Pipeline ("videos-export-segment");
            var vsink = _video_branch (dec, clip);
            var asink = _audio_branch (dec);
            if (vsink == null || asink == null) {
                error = _("A required GStreamer element is missing.");
                return false;
            }
            Gst.Element vhead = dec.get_by_name ("vhead");
            Gst.Element ahead = dec.get_by_name ("ahead");

            if (clip.has_video || clip.has_audio) {
                var src = _make ("uridecodebin");
                src.set ("uri", clip.uri);
                bool video_linked = false;
                bool audio_linked = false;
                dec.add (src);
                src.pad_added.connect ((pad) => {
                    var caps = pad.get_current_caps () ?? pad.query_caps (null);
                    string name = caps != null && caps.get_size () > 0 ? caps.get_structure (0).get_name () : "";
                    Gst.Element? target = null;
                    if (name.has_prefix ("video/") && !video_linked && clip.has_video) {
                        video_linked = true;
                        target = vhead;
                    } else if (name.has_prefix ("audio/") && !audio_linked && clip.has_audio) {
                        audio_linked = true;
                        target = ahead;
                    }
                    if (target == null) {
                        var fake = _make ("fakesink");
                        fake.set ("sync", false);
                        dec.add (fake);
                        fake.sync_state_with_parent ();
                        target = fake;
                    }
                    var sinkpad = target.get_static_pad ("sink");
                    if (sinkpad != null && !sinkpad.is_linked ()) pad.link (sinkpad);
                });
            }
            if (!clip.has_video) {
                var black = _make ("videotestsrc");
                Gst.Util.set_object_arg (black, "pattern", "black");
                dec.add (black);
                black.link (vhead);
            }
            if (!clip.has_audio) {
                var silence = _make ("audiotestsrc");
                Gst.Util.set_object_arg (silence, "wave", "silence");
                dec.add (silence);
                silence.link (ahead);
            }

            _lock.lock ();
            _seg_len = seg.length ();
            _video_end = _offset;
            _audio_end = _offset;
            _lock.unlock ();

            vsink.new_sample.connect (() => _on_video (vsink, seg));
            asink.new_sample.connect (() => _on_audio (asink, seg));

            bool ok = _drive (dec, seg, out error);
            dec.set_state (Gst.State.NULL);
            if (!ok || _is_cancelled ()) return ok;
            _pad_tail ();
            return true;
        }

        private Gst.App.Sink? _video_branch (Gst.Pipeline dec, EditClip clip) {
            var conv = _make ("videoconvert");
            var flip = _make ("videoflip");
            var crop = _make ("videocrop");
            var scale = _make ("videoscale");
            var rate = _make ("videorate");
            var conv2 = _make ("videoconvert");
            var filter = _make ("capsfilter");
            var sink = (Gst.App.Sink?) _make ("appsink");
            if (conv == null || flip == null || crop == null || scale == null || rate == null
                || conv2 == null || filter == null || sink == null) return null;
            conv.name = "vhead";
            Gst.Util.set_object_arg (flip, "method", Geometry.flip_method (_edl.rotation));
            int rw, rh;
            int pw = clip.has_video ? clip.pixel_width () : _width;
            int ph = clip.has_video ? clip.height : _height;
            Geometry.rotated_size (pw, ph, _edl.rotation, out rw, out rh);
            int l, t, r, b;
            _edl.crop.pixels (rw, rh, out l, out t, out r, out b);
            if (clip.has_video) {
                crop.set ("left", l);
                crop.set ("top", t);
                crop.set ("right", r);
                crop.set ("bottom", b);
            }
            scale.set ("add-borders", true);
            filter.set ("caps", Gst.Caps.from_string (
                "video/x-raw,format=I420,width=%d,height=%d,framerate=%d/%d,pixel-aspect-ratio=1/1"
                .printf (_width, _height, _fps_n, _fps_d)));
            sink.sync = false;
            sink.emit_signals = true;
            sink.max_buffers = 4;
            sink.drop = false;
            dec.add_many (conv, flip, crop, scale, rate, conv2, filter, sink);
            if (!conv.link_many (flip, crop, scale, rate, conv2, filter, sink)) return null;
            return sink;
        }

        private Gst.App.Sink? _audio_branch (Gst.Pipeline dec) {
            var conv = _make ("audioconvert");
            var res = _make ("audioresample");
            var filter = _make ("capsfilter");
            var sink = (Gst.App.Sink?) _make ("appsink");
            if (conv == null || res == null || filter == null || sink == null) return null;
            conv.name = "ahead";
            filter.set ("caps", Gst.Caps.from_string (
                "audio/x-raw,format=S16LE,layout=interleaved,rate=%d,channels=%d".printf (RATE, CHANNELS)));
            sink.sync = false;
            sink.emit_signals = true;
            sink.max_buffers = 8;
            sink.drop = false;
            dec.add_many (conv, res, filter, sink);
            if (!conv.link_many (res, filter, sink)) return null;
            return sink;
        }

        private bool _drive (Gst.Pipeline dec, Segment seg, out string? error) {
            error = null;
            var bus = dec.get_bus ();
            if (dec.set_state (Gst.State.PAUSED) == Gst.StateChangeReturn.FAILURE
                || !_wait_async (dec, bus, out error)) {
                if (error == null) error = _("The clip could not be opened.");
                return false;
            }
            if (!dec.seek (1.0, Gst.Format.TIME, Gst.SeekFlags.FLUSH | Gst.SeekFlags.ACCURATE,
                           Gst.SeekType.SET, seg.start, Gst.SeekType.SET, seg.end)) {
                error = _("The clip could not be positioned.");
                return false;
            }
            if (!_wait_async (dec, bus, out error)) return false;
            dec.set_state (Gst.State.PLAYING);
            while (true) {
                if (_is_cancelled ()) return true;
                if (!_encoder_healthy (out error)) return false;
                var msg = bus.timed_pop_filtered (100 * Gst.MSECOND,
                    Gst.MessageType.EOS | Gst.MessageType.ERROR);
                if (msg == null) continue;
                if (msg.type == Gst.MessageType.ERROR) {
                    GLib.Error err;
                    string debug;
                    msg.parse_error (out err, out debug);
                    error = err.message;
                    return false;
                }
                return true;
            }
        }

        private bool _wait_async (Gst.Pipeline dec, Gst.Bus bus, out string? error) {
            error = null;
            int64 deadline = GLib.get_monotonic_time () + 30 * 1000000;
            while (GLib.get_monotonic_time () < deadline) {
                if (_is_cancelled ()) return false;
                var msg = bus.timed_pop_filtered (100 * Gst.MSECOND,
                    Gst.MessageType.ASYNC_DONE | Gst.MessageType.ERROR);
                if (msg == null) continue;
                if (msg.type == Gst.MessageType.ERROR) {
                    GLib.Error err;
                    string debug;
                    msg.parse_error (out err, out debug);
                    error = err.message;
                    return false;
                }
                return true;
            }
            error = _("The clip took too long to open.");
            return false;
        }

        private bool _encoder_healthy (out string? error) {
            error = null;
            var msg = _encode.get_bus ().pop_filtered (Gst.MessageType.ERROR);
            if (msg == null) return true;
            GLib.Error err;
            string debug;
            msg.parse_error (out err, out debug);
            error = err.message;
            return false;
        }

        private bool _wait_encoder (out string? error) {
            error = null;
            var bus = _encode.get_bus ();
            while (true) {
                if (_is_cancelled ()) return false;
                var msg = bus.timed_pop_filtered (100 * Gst.MSECOND,
                    Gst.MessageType.EOS | Gst.MessageType.ERROR);
                if (msg == null) continue;
                if (msg.type == Gst.MessageType.ERROR) {
                    GLib.Error err;
                    string debug;
                    msg.parse_error (out err, out debug);
                    error = err.message;
                    return false;
                }
                return true;
            }
        }

        private void _teardown () {
            if (_encode != null) _encode.set_state (Gst.State.NULL);
            _encode = null;
            _vsrc = null;
            _asrc = null;
            _last_frame = null;
        }

        private Gst.FlowReturn _on_video (Gst.App.Sink sink, Segment seg) {
            var sample = sink.pull_sample ();
            if (sample == null) return Gst.FlowReturn.EOS;
            if (_is_cancelled ()) return Gst.FlowReturn.FLUSHING;
            unowned Gst.Buffer buf = sample.get_buffer ();
            unowned Gst.Segment segment = sample.get_segment ();
            if (buf == null || segment == null || buf.pts == Gst.CLOCK_TIME_NONE) return Gst.FlowReturn.OK;
            uint64 cs, ce;
            uint64 stop = buf.duration != Gst.CLOCK_TIME_NONE ? buf.pts + buf.duration : buf.pts + 1;
            if (!segment.clip (Gst.Format.TIME, buf.pts, stop, out cs, out ce)) return Gst.FlowReturn.OK;
            int64 rt = (int64) segment.to_running_time (Gst.Format.TIME, cs);
            if (rt < 0 || rt >= _seg_len) return Gst.FlowReturn.OK;
            int64 frame = (int64) ((double) Gst.SECOND * _fps_d / _fps_n);
            var out_buf = (Gst.Buffer) buf.copy ();
            out_buf.pts = _offset + rt;
            out_buf.dts = Gst.CLOCK_TIME_NONE;
            out_buf.duration = int64.min (frame, _seg_len - rt);
            _lock.lock ();
            _video_end = int64.max (_video_end, (int64) (out_buf.pts + out_buf.duration));
            _last_frame = (Gst.Buffer) buf.copy ();
            _lock.unlock ();
            position_fraction = (double) (_offset + rt) / _total;
            return _vsrc.push_buffer ((owned) out_buf);
        }

        private Gst.FlowReturn _on_audio (Gst.App.Sink sink, Segment seg) {
            var sample = sink.pull_sample ();
            if (sample == null) return Gst.FlowReturn.EOS;
            if (_is_cancelled ()) return Gst.FlowReturn.FLUSHING;
            unowned Gst.Buffer buf = sample.get_buffer ();
            unowned Gst.Segment segment = sample.get_segment ();
            if (buf == null || segment == null || buf.pts == Gst.CLOCK_TIME_NONE) return Gst.FlowReturn.OK;
            size_t size = buf.get_size ();
            int64 frames = (int64) (size / BYTES_PER_FRAME);
            if (frames <= 0) return Gst.FlowReturn.OK;
            uint64 stop = buf.pts + (uint64) (frames * Gst.SECOND / RATE);
            uint64 cs, ce;
            if (!segment.clip (Gst.Format.TIME, buf.pts, stop, out cs, out ce)) return Gst.FlowReturn.OK;
            int64 rt = (int64) segment.to_running_time (Gst.Format.TIME, cs);
            if (rt < 0 || rt >= _seg_len) return Gst.FlowReturn.OK;
            int64 head = (int64) ((cs - buf.pts) * RATE / Gst.SECOND);
            int64 keep = (int64) ((ce - cs) * RATE / Gst.SECOND);
            int64 room = (int64) ((_seg_len - rt) * RATE / Gst.SECOND);
            keep = int64.min (keep, int64.min (room, frames - head));
            if (keep <= 0) return Gst.FlowReturn.OK;
            var out_buf = buf.copy_region (Gst.BufferCopyFlags.MEMORY | Gst.BufferCopyFlags.FLAGS,
                                           (size_t) (head * BYTES_PER_FRAME), (size_t) (keep * BYTES_PER_FRAME));
            out_buf.pts = _offset + rt;
            out_buf.dts = Gst.CLOCK_TIME_NONE;
            out_buf.duration = keep * Gst.SECOND / RATE;
            _lock.lock ();
            _audio_end = int64.max (_audio_end, (int64) (out_buf.pts + out_buf.duration));
            _lock.unlock ();
            return _asrc.push_buffer ((owned) out_buf);
        }

        private void _pad_tail () {
            int64 end = _offset + _seg_len;
            int64 frame = (int64) ((double) Gst.SECOND * _fps_d / _fps_n);
            _lock.lock ();
            int64 video_end = _video_end;
            int64 audio_end = _audio_end;
            Gst.Buffer? last = _last_frame;
            _lock.unlock ();
            while (last != null && end - video_end > frame / 2 && !_is_cancelled ()) {
                var copy = (Gst.Buffer) last.copy ();
                copy.pts = video_end;
                copy.dts = Gst.CLOCK_TIME_NONE;
                copy.duration = int64.min (frame, end - video_end);
                video_end += (int64) copy.duration;
                _vsrc.push_buffer ((owned) copy);
            }
            while (end - audio_end > Gst.SECOND / RATE && !_is_cancelled ()) {
                int64 frames = int64.min (RATE / 10, (end - audio_end) * RATE / Gst.SECOND);
                if (frames <= 0) break;
                var silence = new Gst.Buffer.allocate (null, (size_t) (frames * BYTES_PER_FRAME), null);
                silence.memset (0, 0, (size_t) (frames * BYTES_PER_FRAME));
                silence.pts = audio_end;
                silence.duration = frames * Gst.SECOND / RATE;
                audio_end += (int64) silence.duration;
                _asrc.push_buffer ((owned) silence);
            }
            _lock.lock ();
            _video_end = video_end;
            _audio_end = audio_end;
            _lock.unlock ();
        }
    }
}
