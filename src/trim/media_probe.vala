namespace Singularity.Apps.Videos {

    namespace MediaProbe {

        public EditClip? probe_sync (string uri, out string? error) {
            error = null;
            try {
                var discoverer = new Gst.PbUtils.Discoverer (20 * Gst.SECOND);
                var info = discoverer.discover_uri (uri);
                if (info.get_result () != Gst.PbUtils.DiscovererResult.OK) {
                    error = _("The file could not be read.");
                    return null;
                }
                var videos = info.get_video_streams ();
                var audios = info.get_audio_streams ();
                if (videos.length () == 0 && audios.length () == 0) {
                    error = _("The file has no audio or video.");
                    return null;
                }
                var clip = new EditClip (uri, (int64) info.get_duration ());
                clip.has_audio = audios.length () > 0;
                clip.has_video = false;
                foreach (var s in videos) {
                    var v = (Gst.PbUtils.DiscovererVideoInfo) s;
                    if (v.is_image ()) continue;
                    clip.has_video = true;
                    clip.width = (int) v.get_width ();
                    clip.height = (int) v.get_height ();
                    uint par_n = v.get_par_num (), par_d = v.get_par_denom ();
                    if (par_n > 0 && par_d > 0 && par_n != par_d) {
                        clip.storage_width = clip.width;
                        clip.width = (int) Math.round ((double) clip.width * par_n / par_d);
                    }
                    if (v.get_framerate_num () > 0 && v.get_framerate_denom () > 0) {
                        clip.fps_n = (int) v.get_framerate_num ();
                        clip.fps_d = (int) v.get_framerate_denom ();
                    }
                    break;
                }
                if (clip.duration <= 0) {
                    error = _("The length of the file is unknown.");
                    return null;
                }
                return clip;
            } catch (GLib.Error e) {
                error = e.message;
                return null;
            }
        }

        public async EditClip? probe (string uri, out string? error) {
            EditClip? result = null;
            string? err = null;
            GLib.SourceFunc cb = probe.callback;
            new GLib.Thread<bool> ("videos-probe", () => {
                result = probe_sync (uri, out err);
                GLib.Idle.add ((owned) cb);
                return true;
            });
            yield;
            error = err;
            return result;
        }
    }
}
