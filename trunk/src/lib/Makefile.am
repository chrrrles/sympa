nobase_modules_DATA = Sympa/Admin.pm \
		      Sympa/Archive.pm \
		      Sympa/Auth.pm \
		      Sympa/BounceMessage.pm \
		      Sympa/Bulk.pm \
		      Sympa/Commands.pm \
		      Sympa/Conf.pm \
		      Sympa/ConfDef.pm \
		      Sympa/Config_XML.pm \
		      Sympa/CookieLib.pm \
		      Sympa/Datasource.pm \
		      Sympa/DBManipulatorDefault.pm \
		      Sympa/DBManipulatorMySQL.pm \
		      Sympa/DBManipulatorOracle.pm \
		      Sympa/DBManipulatorPostgres.pm \
		      Sympa/DBManipulatorSQLite.pm\
		      Sympa/DBManipulatorSybase.pm \
		      Sympa/Family.pm \
		      Sympa/Fetch.pm \
		      Sympa/HTML/MyFormatText.pm \
		      Sympa/KeySpool.pm \
		      Sympa/Language.pm \
		      Sympa/LDAP.pm \
		      Sympa/LDAPSource.pm \
		      Sympa/List.pm \
		      Sympa/ListDef.pm \
		      Sympa/Lock.pm \
		      Log.pm \
		      mail.pm \
		      Marc.pm \
		      Marc/Search.pm \
		      Message.pm \
		      Messagespool.pm \
		      moddef.pm \
		      PlainDigest.pm \
		      report.pm \
		      Robot.pm \
		      Scenario.pm \
		      SDM.pm \
		      SharedDocument.pm \
		      Site.pm \
		      Site_r.pm \
		      SQLSource.pm \
		      SubscribeSpool.pm \
		      Sympa/Constants.pm \
		      Sympa/DatabaseDescription.pm \
		      Sympa/Template/Compat.pm \
		      SympaSession.pm \
		      sympasoap.pm \
		      Sympaspool.pm \
		      SympaspoolClassic.pm \
		      SympaTransport.pm \
		      Task.pm \
		      TaskInstruction.pm \
		      TaskSpool.pm \
		      time_utils.pm \
		      tools.pm \
		      tracking.pm \
		      tt2.pm \
		      Upgrade.pm \
		      User.pm \
		      WebAgent.pm \
		      wwslib.pm

EXTRA_DIST = Sympa/Constants.pm.in $(nobase_modules_DATA)
CLEANFILES = Sympa/Constants.pm

Sympa/Constants.pm: Sympa/Constants.pm.in Makefile
	[ -d Sympa ] || mkdir Sympa
	rm -f $@
	$(AM_V_GEN)$(SED) \
		-e 's|--VERSION--|$(VERSION)|' \
		-e 's|--USER--|$(USER)|' \
		-e 's|--GROUP--|$(GROUP)|' \
		-e 's|--CONFIG--|$(CONFIG)|' \
		-e 's|--WWSCONFIG--|$(WWSCONFIG)|' \
		-e 's|--SENDMAIL_ALIASES--|$(SENDMAIL_ALIASES)|' \
		-e 's|--piddir--|$(piddir)|' \
		-e 's|--expldir--|$(expldir)|' \
		-e 's|--spooldir--|$(spooldir)|' \
		-e 's|--sysconfdir--|$(sysconfdir)|' \
		-e 's|--localedir--|$(localedir)|' \
		-e 's|--libexecdir--|$(libexecdir)|' \
		-e 's|--sbindir--|$(sbindir)|' \
		-e 's|--scriptdir--|$(scriptdir)|' \
		-e 's|--modulesdir--|$(modulesdir)|' \
		-e 's|--defaultdir--|$(defaultdir)|' \
		-e 's|--staticdir--|$(staticdir)|' \
		-e 's|--arcdir--|$(arcdir)|' \
		-e 's|--bouncedir--|$(bouncedir)|' \
		< $(srcdir)/$@.in > $@
