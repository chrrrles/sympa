# Makefile - This Makefile does the Sympa scripts installation
# RCS Identication ; $Revision$ ; $Date$ 
#
# Sympa - SYsteme de Multi-Postage Automatique
# Copyright (c) 1997, 1998, 1999, 2000, 2001 Comite Reseau des Universites
# Copyright (c) 1997,1998, 1999 Institut Pasteur & Christophe Wolfhugel
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

init_SCRIPTS = sympa

EXTRA_DIST = sympa.in

CLEANFILES = $(init_SCRIPTS)

sympa: Makefile
	rm -f $@
	$(AM_V_GEN)$(SED) \
		-e 's|--CONFIG--|$(CONFIG)|' \
		-e 's|--WWSCONFIG--|$(WWSCONFIG)|' \
		-e 's|--sbindir--|$(sbindir)|' \
		-e 's|--initdir--|$(initdir)|' \
		-e 's|--piddir--|$(piddir)|' \
		-e 's|--lockdir--|$(lockdir)|' \
		< $(srcdir)/$@.in > $@
	chmod +x $@

sympa: sympa.in
