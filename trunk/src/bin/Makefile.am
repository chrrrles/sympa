bin_SCRIPTS = sympa_wizard.pl sympa_soap_client.pl

man1_MANS = sympa_wizard.pl.1

dbscripts = create_db.Pg create_db.mysql create_db.Oracle \
	    create_db.Sybase create_db.SQLite

perlscripts = arc2webarc.pl \
	      testldap.pl \
	      p12topem.pl \
	      init_comment.pl \
	      crypt_passwd.pl \
	      testlogs.pl \
	      mod2html.pl \
	      tpl2tt2.pl

script_SCRIPTS = $(dbscripts) $(perlscripts)

EXTRA_DIST = $(dbscripts) \
	     arc2webarc.pl.in \
	     crypt_passwd.pl.in \
	     init_comment.pl.in \
	     mod2html.pl.in \
	     p12topem.pl.in \
	     testldap.pl.in \
	     testlogs.pl.in \
	     tpl2tt2.pl.in \
	     sympa_wizard.pl.in \
	     sympa_soap_client.pl.in

CLEANFILES = $(perlscripts) $(bin_SCRIPTS) $(man1_MANS)

arc2webarc.pl crypt_passwd.pl init_comment.pl mod2html.pl p12topem.pl testldap.pl testlogs.pl tpl2tt2.pl sympa_wizard.pl sympa_soap_client.pl: Makefile
	rm -f $@
	$(AM_V_GEN)$(SED) \
		-e 's|--PERL--|$(PERL)|' \
		-e 's|--defaultdir--|$(defaultdir)|' \
		-e 's|--docdir--|$(docdir)|' \
		-e 's|--libexecdir--|$(libexecdir)|' \
		-e 's|--localedir--|$(localedir)|' \
		-e 's|--modulesdir--|$(modulesdir)|' \
		-e 's|--piddir--|$(piddir)|' \
		-e 's|--spooldir--|$(spooldir)|' \
		-e 's|--sysconfdir--|$(sysconfdir)|' \
		-e 's|--CONFIG--|$(CONFIG)|' \
		-e 's|--SENDMAIL_ALIASES--|$(SENDMAIL_ALIASES)|' \
		< $(srcdir)/$@.in > $@
	chmod +x $@

arc2webarc.pl: $(srcdir)/arc2webarc.pl.in
crypt_passwd.pl: $(srcdir)/crypt_passwd.pl.in
init_comment.pl: $(srcdir)/init_comment.pl.in
mod2html.pl: $(srcdir)/mod2html.pl.in
p12topem.pl: $(srcdir)/p12topem.pl.in
testldap.pl: testldap.pl.in
testlogs.pl: testlogs.pl.in
tpl2tt2.pl: tpl2tt2.pl.in
sympa_wizard.pl: $(srcdir)/sympa_wizard.pl.in
sympa_soap_client.pl: $(srcdir)/sympa_soap_client.pl.in

.pl.1:

sympa_wizard.pl.1: Makefile
	rm -f $@
	$(AM_V_GEN)$(POD2MAN) --section=1 --center="sympa $(VERSION)" \
		--lax --release="$(VERSION)" $* $@

sympa_wizard.pl.1: sympa_wizard.pl
