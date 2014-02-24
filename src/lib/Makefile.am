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
		      Sympa/DatabaseManager.pm \
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
		      Sympa/Log.pm \
		      Sympa/Mail.pm \
		      Sympa/Marc.pm \
		      Sympa/Marc/Search.pm \
		      Sympa/Message.pm \
		      Sympa/MessageSpool.pm \
		      Sympa/ModDef.pm \
		      Sympa/PlainDigest.pm \
		      Sympa/Report.pm \
		      Sympa/Robot.pm \
		      Sympa/Scenario.pm \
		      Sympa/SharedDocument.pm \
		      Sympa/Site.pm \
		      Sympa/Site_r.pm \
		      Sympa/SQLSource.pm \
		      Sympa/SubscribeSpool.pm \
		      Sympa/Constants.pm \
		      Sympa/DatabaseDescription.pm \
		      Sympa/Template/Compat.pm \
		      Sympa/Session.pm \
		      Sympa/SOAP.pm \
		      Sympa/Spool.pm \
		      Sympa/ClassicSpool.pm \
		      Sympa/Transport.pm \
		      Sympa/Task.pm \
		      Sympa/TaskInstruction.pm \
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
