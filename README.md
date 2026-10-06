# Singularity Videos

> [!IMPORTANT]
> Report bugs and request features in the
> [Singularity Desktop tracker](https://github.com/singularityos-lab/singularity-desktop/issues/new/choose).

Video player for the Singularity Desktop.

## Requirements

- [Meson](https://mesonbuild.com/) >= 0.59
- [Vala](https://vala.dev/) compiler
- [Vetro](https://github.com/singularityos-lab/vetro/) compiler
- GTK4, libgee-0.8, gstreamer-1.0, gstreamer-video-1.0, gstreamer-app-1.0,
  gstreamer-pbutils-1.0
- Optional: gst-editing-services-1.0
- [libsingularity](https://github.com/singularityos-lab/libsingularity)

## Trim mode

Videos includes a Trim mode for quick edits: trim the start and end of a
clip, cut out any number of parts, join several clips in any order, crop and
rotate, then export for the web as MP4 (H.264 and AAC) or WebM (VP9 and Opus)
with High, Medium or Small presets. Open it from the Trim button while a video
plays, from Trim Video in the Edit menu, from the start screen, or with
`singularity-videos --trim FILE...`.

## For distributors

Trim mode only needs GStreamer and asks it at run time which elements exist.

- **Export backends.** The plain GStreamer pipeline backend is always built.
  With GStreamer Editing Services installed at build time
  (`-Dges=enabled`, default `auto`) the GES backend is built as well and is
  preferred when its `nlecomposition` element is present at run time.
- **Encoders.** Each format is offered only when a video encoder, an audio
  encoder and a muxer are installed. The defaults are tried in order:
  `x264enc`, `openh264enc` for H.264; `fdkaacenc`, `voaacenc`, `avenc_aac`
  for AAC; `mp4mux`, `qtmux`; `vp9enc`, `opusenc` and `webmmux` for WebM.
- **Configuration.** `singularity/videos-export.conf` is read from
  `$XDG_CONFIG_HOME` and then from each directory in `$XDG_CONFIG_DIRS`
  (for example `/etc/xdg`). The first file found wins:

  ```ini
  [Export]
  backend=auto

  [Encoders]
  h264=x264enc;openh264enc
  aac=fdkaacenc;voaacenc;avenc_aac
  mp4-muxer=mp4mux;qtmux
  vp9=vp9enc
  opus=opusenc
  webm-muxer=webmmux
  ```

  `backend` accepts `auto`, `ges` or `pipeline`. Put hardware encoders first
  in a list to prefer them. `SINGULARITY_VIDEOS_EXPORT_BACKEND` and
  `SINGULARITY_VIDEOS_EXPORT_CONF` override both for testing.
- **Tests.** `meson test` runs the edit list unit tests and an export test
  that renders synthetic clips and checks the results; the export test is
  skipped when `x264enc` or `voaacenc` is missing. The `videos-export` tool
  built next to the app runs the same export code from the command line.

## Build & Install

```sh
meson setup build
meson compile -C build
meson install -C build
```

## License

GPL-3.0-only, see [LICENSE](LICENSE).

## Use of Generative AI

Maintainers may use generative AI tools as assistants while working on singularity-videos. Non-trivial assisted commits disclose the tool, model, and scope of the work.

AI tools may assist with code comments, documentation, repetitive code, and issue triage. Maintainers make project decisions and review every assisted change before it is merged.

Use these trailers for non-trivial assisted commits:

```plain
Assisted-by: <tool>:<model-version>
AI-Scope: <what the tool generated and the prompt or a short prompt summary>
```

Single-line completions, renames, and formatting changes do not need trailers.

Coding agents must also follow [AGENTS.md](AGENTS.md) before changing files,
creating commits, or opening pull requests.
