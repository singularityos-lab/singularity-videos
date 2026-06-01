# Singularity Videos

Video player for the Singularity Desktop.

## Requirements

- [Meson](https://mesonbuild.com/) >= 0.59
- [Vala](https://vala.dev/) compiler
- [Vetro](https://github.com/singularityos-lab/vetro/) compiler
- GTK4, libgee-0.8, gstreamer-1.0, gstreamer-video-1.0
- [libsingularity](https://github.com/singularityos-lab/libsingularity)

## Build & Install

```sh
meson setup build
meson compile -C build
meson install -C build
```

## License

GPL-3.0-only, see [LICENSE](LICENSE).
