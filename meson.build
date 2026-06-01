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
)

executable('singularity-videos',
  sources + [resources],
  dependencies: [gtk_dep, gee_dep, gst_dep, gst_video_dep, math_dep, libsingularity_dep],
  install: true
)

install_data('data/dev.sinty.videos.desktop',
  install_dir: get_option('datadir') / 'applications'
)
install_data('data/dev.sinty.videos.json',
  install_dir: get_option('datadir') / 'singularity' / 'apps'
)
install_data('data/icons/dev.sinty.videos.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)
