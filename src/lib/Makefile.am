# Sympa - SYsteme de Multi-Postage Automatique
#
# Copyright (c) 1997, 1998, 1999 Institut Pasteur & Christophe Wolfhugel
# Copyright (c) 1997, 1998, 1999, 2000, 2001, 2002, 2003, 2004, 2005,
# 2006, 2007, 2008, 2009, 2010, 2011 Comite Reseau des Universites
# Copyright (c) 2011, 2012, 2013, 2014 GIP RENATER
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

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
		      Sympa/LockedFile.pm \
		      Sympa/Log/Syslog.pm \
		      Sympa/Log/Database.pm \
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
		      Sympa/TaskSpool.pm \
		      Sympa/TimeUtils.pm \
		      Sympa/Tools.pm \
		      Sympa/Tools/SMIME.pm \
		      Sympa/Tools/DKIM.pm \
		      Sympa/Tracking.pm \
		      Sympa/Template.pm \
		      Sympa/Upgrade.pm \
		      Sympa/User.pm \
		      Sympa/Wwslib.pm

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
