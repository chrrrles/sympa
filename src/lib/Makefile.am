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
		      Sympa/DatabaseManager.pm \
		      Sympa/Datasource.pm \
		      Sympa/DBManipulator.pm \
		      Sympa/DBManipulator/MySQL.pm \
		      Sympa/DBManipulator/Oracle.pm \
		      Sympa/DBManipulator/Postgres.pm \
		      Sympa/DBManipulator/SQLite.pm\
		      Sympa/DBManipulator/Sybase.pm \
		      Sympa/Family.pm \
		      Sympa/Fetch.pm \
		      Sympa/HTML/MyFormatText.pm \
		      Sympa/Instruction.pm \
		      Sympa/Language.pm \
		      Sympa/LDAP.pm \
		      Sympa/LDAPSource.pm \
		      Sympa/List.pm \
		      Sympa/ListDef.pm \
		      Sympa/LockedFile.pm \
		      Sympa/Log/Syslog.pm \
		      Sympa/Log/Database.pm \
		      Sympa/Mailer.pm \
		      Sympa/Marc.pm \
		      Sympa/Marc/Search.pm \
		      Sympa/Message.pm \
		      Sympa/ModDef.pm \
		      Sympa/Report.pm \
		      Sympa/Robot.pm \
		      Sympa/Scenario.pm \
		      Sympa/SharedDocument.pm \
		      Sympa/Site.pm \
		      Sympa/Site_r.pm \
		      Sympa/Spool/File.pm \
		      Sympa/Spool/File/Key.pm \
		      Sympa/Spool/File/Message.pm \
		      Sympa/Spool/File/Subscribe.pm \
		      Sympa/Spool/File/Task.pm \
		      Sympa/Spool/SQL.pm \
		      Sympa/SQLSource.pm \
		      Sympa/Constants.pm \
		      Sympa/DatabaseDescription.pm \
		      Sympa/Template/Compat.pm \
		      Sympa/Session.pm \
		      Sympa/SOAP.pm \
		      Sympa/Transport.pm \
		      Sympa/Task.pm \
		      Sympa/Tools.pm \
		      Sympa/Tools/Cookie.pm \
		      Sympa/Tools/SMIME.pm \
		      Sympa/Tools/DKIM.pm \
		      Sympa/Tools/Data.pm \
		      Sympa/Tools/Daemon.pm \
		      Sympa/Tools/File.pm \
		      Sympa/Tools/Message.pm \
		      Sympa/Tools/Password.pm \
		      Sympa/Tools/Time.pm \
		      Sympa/Tools/Text.pm \
		      Sympa/Tools/WWW.pm
		      Sympa/Tracking.pm \
		      Sympa/Template.pm \
		      Sympa/Upgrade.pm \
		      Sympa/User.pm

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
