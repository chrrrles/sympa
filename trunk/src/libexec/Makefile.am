libexec_SCRIPTS = alias_manager.pl \
		  ldap_alias_manager.pl \
		  mysql_alias_manager.pl

man8_MANS = alias_manager.8

EXTRA_DIST = alias_manager.pl.in \
	     ldap_alias_manager.pl.in \
	     mysql_alias_manager.pl.in

CLEANFILES = $(libexec_SCRIPTS) $(man8_MANS)

libexec_PROGRAMS = aliaswrapper virtualwrapper queue bouncequeue familyqueue

AM_CPPFLAGS = -DCONFIG=\"$(CONFIG)\"

aliaswrapper_SOURCES = aliaswrapper.c
aliaswrapper_CPPFLAGS = $(AM_CPPFLAGS) \
			-DNEWALIASES=\"${NEWALIASES}\" \
			-DNEWALIASES_ARG=\"${NEWALIASES_ARG}\"

virtualwrapper_SOURCES = virtualwrapper.c
virtualwrapper_CPPFLAGS = $(AM_CPPFLAGS) \
			  -DPOSTMAP=\"${POSTMAP}\" \
			  -DPOSTMAP_ARG=\"${POSTMAP_ARG}\"
queue_SOURCES = queue.c
queue_CPPFLAGS = $(AM_CPPFLAGS) \
		 -DSPOOLDIR=\"${spooldir}\"

bouncequeue_SOURCES = bouncequeue.c
bouncequeue_CPPFLAGS = $(AM_CPPFLAGS) \
		       -DSPOOLDIR=\"${spooldir}\"

familyqueue_SOURCES = familyqueue.c
familyqueue_CPPFLAGS = $(AM_CPPFLAGS) \
		       -DSPOOLDIR=\"${spooldir}\"

install-exec-hook:
	-chown $(USER) $(DESTDIR)$(libexecdir)/queue
	-chgrp $(GROUP) $(DESTDIR)$(libexecdir)/queue
	chmod 4755 $(DESTDIR)$(libexecdir)/queue

	-chown $(USER) $(DESTDIR)$(libexecdir)/bouncequeue
	-chgrp $(GROUP) $(DESTDIR)$(libexecdir)/bouncequeue
	chmod 4755 $(DESTDIR)$(libexecdir)/bouncequeue

	-chown $(USER) $(DESTDIR)$(libexecdir)/familyqueue
	-chgrp $(GROUP) $(DESTDIR)$(libexecdir)/familyqueue
	chmod 4755 $(DESTDIR)$(libexecdir)/familyqueue

	-chown root $(DESTDIR)$(libexecdir)/aliaswrapper
	-chgrp $(GROUP) $(DESTDIR)$(libexecdir)/aliaswrapper
	chmod 4750 aliaswrapper $(DESTDIR)$(libexecdir)/aliaswrapper

	-chown root $(DESTDIR)$(libexecdir)/virtualwrapper
	-chgrp $(GROUP) $(DESTDIR)$(libexecdir)/virtualwrapper
	chmod 4750 $(DESTDIR)$(libexecdir)/virtualwrapper

alias_manager.pl ldap_alias_manager.pl mysql_alias_manager.pl: Makefile
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

alias_manager.pl: $(srcdir)/alias_manager.pl.in
ldap_alias_manager.pl: $(srcdir)/ldap_alias_manager.pl.in
mysql_alias_manager.pl: $(srcdir)/mysql_alias_manager.pl.in

.pl.8:

alias_manager.8: Makefile
	rm -f $@
	$(AM_V_GEN)$(POD2MAN) --section=8 --center="sympa $(VERSION)" \
		--lax --release="$(VERSION)" $*.pl $@

alias_manager.8: alias_manager.pl
