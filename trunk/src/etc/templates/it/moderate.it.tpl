From: [from]
To: Moderatori della lista [list->name] <[list->name]-editor@[list->host]>
Subject: Messaggio da approvare
Mime-version: 1.0
Content-Type: multipart/mixed; boundary="[boundary]"

--[boundary]
Content-Type: text/plain; charset=iso-8859-1
Content-transfer-encoding: 8bit

Per inoltrare il messaggio allegato alla lista '[list->name]' :\n\
mailto:[conf->email]@[conf->host]?subject=DISTRIBUTE%%20[list->name]%%20[modkey]\n\n

Per respingerlo (sara' cancellato) :\n\
mailto:[conf->email]@[conf->host]?subject=REJECT%%20[list->name]%%20[modkey]

--[boundary]
Content-Type: message/rfc822
Content-Transfer-Encoding: 8bit
Content-Disposition: inline

[INCLUDE msg]

--[boundary]--

