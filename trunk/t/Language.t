#!/usr/bin/perl
# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id$

use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/../src/lib";

use Test::More;

use Sympa::Language;

my @setlang_tests = (
    [ 'C'     , undef ],
    [ 'POSIX' , undef ]
);

my @lang2locale_tests = (
    [ 'ca',    'ca'    ],
    [ 'cs',    'cs'    ],
    [ 'en',    'en'    ],
    [ 'en-US', 'en_US' ],
    [ 'ja-JP', 'ja_JP' ],
    [ 'nb',    'nb'    ],
    [ 'nb-NO', 'nb_NO' ], # not recommended but possible'
    [ 'pt',    'pt'    ],
    [ 'pt-BR', 'pt_BR' ],
    [ 'zh',    'zh'    ],
    [ 'zh-CN', 'zh_CN' ],
    [ 'cz',    'cs'    ],
    [ 'us',    'en_US' ],
    [ 'cn',    'zh_CN' ],
    [ 'en_US', 'en_US' ],
    [ 'ja_JP', 'ja'    ],
    [ 'nb_NO', 'nb'    ],
    [ 'pt_BR', 'pt_BR' ],
    [ 'zh_CN', 'zh_CN' ],
    # Complex locales
    [ 'ca-ES-valencia', 'ca_ES@valencia' ],
    [ 'be-Latn',        'be@latin'       ],
    [ 'tyv-Latn-MN',    'tyv_MN@latin'   ],
);

my @lang2locale_old_tests = (
    [ 'ca',    'ca_ES' ],
    [ 'cs',    'cs_CZ' ],
    [ 'en',    undef   ],
    [ 'en-US', 'en_US' ],
    [ 'ja-JP', 'ja_JP' ],
    [ 'nb',    'nb_NO' ],
    [ 'nb-NO', 'nb_NO' ],
    [ 'pt',    'pt_PT' ],
    [ 'pt-BR', 'pt_BR' ],
    [ 'zh',    undef   ],
    [ 'zh-CN', 'zh_CN' ],
    [ 'cz',    'cs_CZ' ],
    [ 'us',    'en_US' ],
    [ 'cn',    'zh_CN' ],
    [ 'en_US', 'en_US' ],
    [ 'ja_JP', 'ja_JP' ],
    [ 'nb_NO', 'nb_NO' ],
    [ 'pt_BR', 'pt_BR' ],
    [ 'zh_CN', 'zh_CN' ],
);

my @canoniclang_tests = (
    [ 'C',     undef   ],
    [ 'POSIX', undef   ],
    [ 'ca',    'ca'    ],
    [ 'cs',    'cs'    ],
    [ 'en',    'en'    ],
    [ 'en-US', 'en-US' ],
    [ 'ja-JP', 'ja-JP' ],
    [ 'nb',     'nb'   ],
    [ 'nb-NO', 'nb-NO' ], # not recommended but possible
    [ 'pt',    'pt'    ],
    [ 'pt-BR', 'pt-BR' ],
    [ 'zh',    'zh'    ],
    [ 'zh-CN', 'zh-CN' ],
    [ 'cz',    'cs'    ],
    [ 'us',    'en-US' ],
    [ 'cn',    'zh-CN' ],
    [ 'en_US', 'en-US' ],
    [ 'ja_JP', 'ja'    ],
    [ 'nb_NO', 'nb'    ],
    [ 'pt_BR', 'pt-BR' ],
    [ 'zh_CN', 'zh-CN' ],
);

my @implicatedlangs_tests = (
    [ 'ca',               [ qw/ca/                          ] ],
    [ 'en-US',            [ qw/en-US en/                    ] ],
    [ 'ca-ES-valencia',   [ qw/ca-ES-valencia ca-ES ca/     ] ],
    [ 'be-Latn',          [ qw/be-Latn be/                  ] ],
    [ 'tyv-Latn-MN',      [ qw/tyv-Latn-MN tyv-Latn tyv/    ] ],
    [ 'cn',               [ qw/zh-CN zh/                    ] ],
    [ 'en_US',            [ qw/en-US en/                    ] ],
    [ 'nb_NO',            [ qw/nb/                          ] ],
    # zh-Hans-*/zh-Hant-* workaround
    [ 'zh-Hans-CN',       [ qw/zh-Hans-CN zh-CN zh-Hans zh/ ] ],
    [ 'zh-Hant-HK-xxxxx', [ qw/zh-Hant-HK-xxxxx zh-HK-xxxxx
        zh-Hant-HK zh-HK zh-Hant zh/ ] ],
);

my @negotiatelang_tests = (
    [ [ 'DE,en,fr;Q=0.5,es;q=0.1', 'es,fr,de,en'    ], 'de'    ],
    [ [ 'en',                      'EN-CA,en'       ], 'en-CA' ],
    [ [ 'en-US',                   'en,en-CA,en-US' ], 'en-US' ],
);

plan tests =>
    scalar @setlang_tests         +
    scalar @lang2locale_tests     +
    scalar @lang2locale_old_tests +
    scalar @canoniclang_tests     +
    scalar @implicatedlangs_tests +
    scalar @negotiatelang_tests;

Sympa::Log::Syslog::set_log_level(-1);

## Unknown language
foreach my $test (@setlang_tests) {
    is(
        Sympa::Language::SetLang($test->[0]),
        $test->[1],
        "SetLang test for $test->[0]"
    );
}

## Lang 2 locale
foreach my $test (@lang2locale_tests) {
    is(
        Sympa::Language::Lang2Locale($test->[0]),
        $test->[1],
        "Lang2Locale test for $test->[0]"
    );
}

## Old style locale
foreach my $test (@lang2locale_old_tests) {
    is(
        Sympa::Language::Lang2Locale_old($test->[0]),
        $test->[1],
        "Lang2Locale_old test for $test->[0]"
    );
}

## Canonical names
# not language tag
foreach my $test (@canoniclang_tests) {
    is(
        Sympa::Language::CanonicLang($test->[0]),
        $test->[1],
        "CanonicLang test for $test->[0]"
    );
}

## Implicated langs
foreach my $test (@implicatedlangs_tests) {
    is_deeply(
        [Sympa::Language::ImplicatedLangs($test->[0])],
        $test->[1],
        "ImplicatedLangs test for $test->[0]"
    );
}

## Content negotiation
foreach my $test (@negotiatelang_tests) {
    is(
        Sympa::Language::NegotiateLang(@{$test->[0]}),
        $test->[1],
        "NegociateLang test for ". join(' ', @{$test->[0]})
    );
}
