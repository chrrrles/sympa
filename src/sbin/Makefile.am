sbin_SCRIPTS = archived.pl \
	       bounced.pl \
	       bulk.pl \
	       sympa.pl \
	       task_manager.pl

man8_MANS = archived.pl.8 \
	    bounced.pl.8 \
	    bulk.pl.8 \
	    sympa.pl.8 \
	    task_manager.pl.8

EXTRA_DIST = archived.pl.in \
	     bounced.pl.in \
	     bulk.pl.in \
	     sympa.pl.in \
	     task_manager.pl.in

CLEANFILES = $(sbin_SCRIPTS) $(man8_MANS)

archived.pl bounced.pl bulk.pl sympa.pl task_manager.pl: Makefile
	rm -f $@
	$(AM_V_GEN)$(SED) \
		-e 's|--PERL--|$(PERL)|' \
		-e 's|--defaultdir--|$(defaultdir)|' \
		-e 's|--docdir--|$(docdir)|' \
		-e 's|--libexecdir--|$(libexecdir)|' \
		-e 's|--modulesdir--|$(modulesdir)|' \
		-e 's|--piddir--|$(piddir)|' \
		-e 's|--spooldir--|$(spooldir)|' \
		-e 's|--CONFIG--|$(CONFIG)|' \
		< $(srcdir)/$@.in > $@
	chmod +x $@

archived.pl: $(srcdir)/archived.pl.in
bounced.pl: $(srcdir)/bounced.pl.in
bulk.pl: $(srcdir)/bulk.pl.in
sympa.pl: $(srcdir)/sympa.pl.in
task_manager.pl: $(srcdir)/task_manager.pl.in

archived.pl.8 bounced.pl.8 bulk.pl.8 sympa.pl.8 task_manager.pl.8: Makefile
	rm -f $@
	$(AM_V_GEN)$(POD2MAN) --section=8 --center="sympa $(VERSION)" \
		--lax --release="$(VERSION)" $* $@

.pl.8:

archived.pl.8: archived.pl
bounced.pl.8: bounced.pl
bulk.pl.8: bulk.pl
sympa.pl.8: sympa.pl
task_manager.pl.8: task_manager.pl
