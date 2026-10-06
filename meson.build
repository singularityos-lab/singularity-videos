project('singularity-videos', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-videos"', language: 'c')
subdir('po')

gnome = import('gnome')
cc    = meson.get_compiler('c')

gtk_dep       = dependency('gtk4')
gee_dep       = dependency('gee-0.8')
gst_dep       = dependency('gstreamer-1.0')
gst_video_dep = dependency('gstreamer-video-1.0')
gst_app_dep   = dependency('gstreamer-app-1.0')
gst_pbutils_dep = dependency('gstreamer-pbutils-1.0')
ges_dep       = dependency('gst-editing-services-1.0', required: get_option('ges'))
math_dep      = cc.find_library('m')

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

subdir('ui')

resources = gnome.compile_resources(
  'singularity-videos-resources',
  'resources/dev.sinty.videos.gresource.xml',
  source_dir: [meson.current_source_dir(), meson.current_build_dir()],
  dependencies: main_ui
)

sources = files(
  'src/main.vala',
  'src/player_window.vala',
  'src/gst_player.vala',
  'src/history.vala',
  'src/mpris.vala',
  'src/seek_bar.vala',
  'src/library/local_source.vala',
  'src/library/thumbnails.vala',
  'src/library/media_bin.vala',
  'src/library/poster_frame.vala',
  'src/library/browse_page.vala',
  'src/library/embed_page.vala',
  'src/library/library.vala',
)

trim_core = files(
  'src/trim/edit_list.vala',
  'src/trim/export_settings.vala',
  'src/trim/media_probe.vala',
  'src/trim/export_backend.vala',
  'src/trim/pipeline_exporter.vala',
)
trim_deps = [dependency('gio-2.0'), gee_dep, gst_dep, gst_video_dep, gst_app_dep, gst_pbutils_dep, math_dep]
trim_args = []
if ges_dep.found()
  trim_core += files('src/trim/ges_exporter.vala')
  trim_deps += [ges_dep]
  trim_args += ['-D', 'HAVE_GES']
endif

trim_ui = files(
  'src/trim/media_strip.vala',
  'src/trim/trim_canvas.vala',
  'src/trim/trim_timeline.vala',
  'src/trim/trim_view.vala',
  'src/trim/export_dialog.vala',
)

executable('singularity-videos',
  sources + trim_core + trim_ui + [resources],
  dependencies: [gtk_dep, libsingularity_dep, dependency('libsoup-3.0'), dependency('json-glib-1.0'), dependency('libpeas-2')] + trim_deps,
  vala_args: trim_args,
  install: true
)

videos_export = executable('videos-export',
  trim_core + files('src/trim/export_cli.vala'),
  dependencies: trim_deps,
  vala_args: trim_args,
)

edit_list_test = executable('edit-list-test',
  trim_core + files('tests/edit_list_test.vala'),
  dependencies: trim_deps,
  vala_args: trim_args,
)
test('edit-list', edit_list_test)

export_test = executable('export-test',
  trim_core + files('tests/export_test.vala'),
  dependencies: trim_deps,
  vala_args: trim_args,
)
test('export', export_test, timeout: 900, is_parallel: false)

shared_module('videos-recent',
  files('plugin/videos_recent.vala', 'src/history.vala'),
  dependencies: [gtk_dep, libsingularity_dep, dependency('libpeas-2'), dependency('gio-unix-2.0')],
  install: true,
  install_dir: get_option('libdir') / 'singularity' / 'plugins' / 'videos-recent'
)
install_data('plugin/videos-recent.plugin',
  install_dir: get_option('libdir') / 'singularity' / 'plugins' / 'videos-recent'
)

install_data('data/dev.sinty.videos.desktop',
  install_dir: get_option('datadir') / 'applications'
)
install_data('data/dev.sinty.videos.json',
  install_dir: get_option('datadir') / 'singularity' / 'apps'
)
install_data('data/app-settings/dev.sinty.videos.json',
  install_dir: get_option('datadir') / 'singularity' / 'app-settings'
)
install_data('data/dev.sinty.videos.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas'
)
install_data('data/icons/dev.sinty.videos.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)
