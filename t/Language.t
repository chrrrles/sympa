#-*- perl -*-
# -*- indent-tabs-mode: t; -*-
# vim:ft=perl:noet:sw=8
# $Id$

use strict;
use warnings;
#use lib "...";

use Test::More;

use Sympa::Language;

plan tests => 77;

Sympa::Log::set_log_level(-1);

## Unknown language
is(Sympa::Language::SetLang('C'),     undef);
is(Sympa::Language::SetLang('POSIX'), undef);

## Lang 2 locale
is(Sympa::Language::Lang2Locale('ca'),    'ca');
is(Sympa::Language::Lang2Locale('cs'),    'cs');
is(Sympa::Language::Lang2Locale('en'),    'en');
is(Sympa::Language::Lang2Locale('en-US'), 'en_US');
is(Sympa::Language::Lang2Locale('ja-JP'), 'ja_JP');
is(Sympa::Language::Lang2Locale('nb'),    'nb');
is(Sympa::Language::Lang2Locale('nb-NO'),
	'nb_NO', '"nb-NO": not recommended but possible');
is(Sympa::Language::Lang2Locale('pt'),    'pt');
is(Sympa::Language::Lang2Locale('pt-BR'), 'pt_BR');
is(Sympa::Language::Lang2Locale('zh'),    'zh');
is(Sympa::Language::Lang2Locale('zh-CN'), 'zh_CN');

is(Sympa::Language::Lang2Locale('cz'), 'cs');
is(Sympa::Language::Lang2Locale('us'), 'en_US');
is(Sympa::Language::Lang2Locale('cn'), 'zh_CN');

is(Sympa::Language::Lang2Locale('en_US'), 'en_US');
is(Sympa::Language::Lang2Locale('ja_JP'), 'ja');
is(Sympa::Language::Lang2Locale('nb_NO'), 'nb');
is(Sympa::Language::Lang2Locale('pt_BR'), 'pt_BR');
is(Sympa::Language::Lang2Locale('zh_CN'), 'zh_CN');

## Complex locales
is(Sympa::Language::Lang2Locale('ca-ES-valencia'), 'ca_ES@valencia');
is(Sympa::Language::Lang2Locale('be-Latn'),        'be@latin');
is(Sympa::Language::Lang2Locale('tyv-Latn-MN'),    'tyv_MN@latin');

## Old style locale
is(Sympa::Language::Lang2Locale_old('ca'),    'ca_ES');
is(Sympa::Language::Lang2Locale_old('cs'),    'cs_CZ');
is(Sympa::Language::Lang2Locale_old('en'),    undef);
is(Sympa::Language::Lang2Locale_old('en-US'), 'en_US');
is(Sympa::Language::Lang2Locale_old('ja-JP'), 'ja_JP');
is(Sympa::Language::Lang2Locale_old('nb'),    'nb_NO');
is(Sympa::Language::Lang2Locale_old('nb-NO'), 'nb_NO');
is(Sympa::Language::Lang2Locale_old('pt'),    'pt_PT');
is(Sympa::Language::Lang2Locale_old('pt-BR'), 'pt_BR');
is(Sympa::Language::Lang2Locale_old('zh'),    undef);
is(Sympa::Language::Lang2Locale_old('zh-CN'), 'zh_CN');

is(Sympa::Language::Lang2Locale_old('cz'), 'cs_CZ');
is(Sympa::Language::Lang2Locale_old('us'), 'en_US');
is(Sympa::Language::Lang2Locale_old('cn'), 'zh_CN');

is(Sympa::Language::Lang2Locale_old('en_US'), 'en_US');
is(Sympa::Language::Lang2Locale_old('ja_JP'), 'ja_JP');
is(Sympa::Language::Lang2Locale_old('nb_NO'), 'nb_NO');
is(Sympa::Language::Lang2Locale_old('pt_BR'), 'pt_BR');
is(Sympa::Language::Lang2Locale_old('zh_CN'), 'zh_CN');

## Canonical names
# not language tag
is(Sympa::Language::CanonicLang('C'),     undef);
is(Sympa::Language::CanonicLang('POSIX'), undef);

is(Sympa::Language::CanonicLang('ca'),    'ca');
is(Sympa::Language::CanonicLang('cs'),    'cs');
is(Sympa::Language::CanonicLang('en'),    'en');
is(Sympa::Language::CanonicLang('en-US'), 'en-US');
is(Sympa::Language::CanonicLang('ja-JP'), 'ja-JP');
is(Sympa::Language::CanonicLang('nb'),    'nb');
is(Sympa::Language::CanonicLang('nb-NO'),
	'nb-NO', '"nb-NO": not recommended but possible');
is(Sympa::Language::CanonicLang('pt'),    'pt');
is(Sympa::Language::CanonicLang('pt-BR'), 'pt-BR');
is(Sympa::Language::CanonicLang('zh'),    'zh');
is(Sympa::Language::CanonicLang('zh-CN'), 'zh-CN');

is(Sympa::Language::CanonicLang('cz'), 'cs');
is(Sympa::Language::CanonicLang('us'), 'en-US');
is(Sympa::Language::CanonicLang('cn'), 'zh-CN');

is(Sympa::Language::CanonicLang('en_US'), 'en-US');
is(Sympa::Language::CanonicLang('ja_JP'), 'ja');
is(Sympa::Language::CanonicLang('nb_NO'), 'nb');
is(Sympa::Language::CanonicLang('pt_BR'), 'pt-BR');
is(Sympa::Language::CanonicLang('zh_CN'), 'zh-CN');

## Implicated langs
is_deeply([Sympa::Language::ImplicatedLangs('ca')], ['ca']);
is_deeply([Sympa::Language::ImplicatedLangs('en-US')], ['en-US', 'en']);
is_deeply([Sympa::Language::ImplicatedLangs('ca-ES-valencia')],
	['ca-ES-valencia', 'ca-ES', 'ca']);
is_deeply([Sympa::Language::ImplicatedLangs('be-Latn')], ['be-Latn', 'be']);
is_deeply(
	[Sympa::Language::ImplicatedLangs('tyv-Latn-MN')],
	['tyv-Latn-MN', 'tyv-Latn', 'tyv']
);

# zh-Hans-*/zh-Hant-* workaround
is_deeply(
	[Sympa::Language::ImplicatedLangs('zh-Hans-CN')],
	['zh-Hans-CN', 'zh-CN', 'zh-Hans', 'zh'],
	'workaround for "zh-Hans-CN"'
);
is_deeply(
	[Sympa::Language::ImplicatedLangs('zh-Hant-HK-xxxxx')],
	[       'zh-Hant-HK-xxxxx', 'zh-HK-xxxxx',
		'zh-Hant-HK',       'zh-HK',
		'zh-Hant',          'zh'
	],
	'workaround for "zh-Hant-HK"'
);

is_deeply([Sympa::Language::ImplicatedLangs('cn')], ['zh-CN', 'zh']);

is_deeply([Sympa::Language::ImplicatedLangs('en_US')], ['en-US', 'en']);
is_deeply([Sympa::Language::ImplicatedLangs('nb_NO')], ['nb']);

## Content negotiation
is(Sympa::Language::NegotiateLang('DE,en,fr;Q=0.5,es;q=0.1', 'es,fr,de,en'), 'de');
is(Sympa::Language::NegotiateLang('en',    'EN-CA,en'),       'en-CA');
is(Sympa::Language::NegotiateLang('en-US', 'en,en-CA,en-US'), 'en-US');

