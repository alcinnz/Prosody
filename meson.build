project('com.github.alcinnz.prosody', ['vala', 'c'],
    version: '1.0.0',
    license: 'GNU',
    meson_version: '>=0.40.1')

lib = library('prosody',
	'data.vala',
    'expression.vala',
    'lib.vala',
    'loader.vala',
    'parser.vala',
    'writers.vala',

    'diff.vala',
    'i18n.vala',
    'json.vala',
    'test.vala',
    'tsv.vala',
    'xml.vala',

    dependencies: [dependency('gee-0.8'), dependency('gio-2.0'), dependency('libsoup-2.4'),
                dependency('json-glib-1.0'), dependency('libxml-2.0')],
    link_args: ['-lm'],
    install: true
)

executable('prosody',
    'Main.vala',

    dependencies: [dependency('gio-2.0'), dependency('gee-0.8'), dependency('libxml-2.0'), dependency('json-glib-1.0')],
    link_with: lib,
    link_args: ['-lm'],
    install: true
)
