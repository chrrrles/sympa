[IF action=search_list]
  [occurrence] risultati trovati<BR><BR>
[ENDIF]

<TABLE BORDER="0" WIDTH="100%">
   [FOREACH l IN which]
     <TR>
     [IF l->admin]
       <TD BGCOLOR="#330099">
          <TABLE BORDER="0" WIDTH="100%" CELLSPACING="0" CELLPADDING="1">
           <TR><TD BGCOLOR="#ccccff" ALIGN="center" VALIGN="top">
             <FONT COLOR="#3366cc" SIZE="-1">
              <A HREF="[base_url][path_cgi]/admin/[l->NAME]" STYLE="TEXT-DECORATION: NONE"><b>amministra</b></A>
         </FONT>
       </TD>
     </TR>
 </TABLE>
</TD>
     [ELSE]
       <TD>&nbsp;</TD>
     [ENDIF] 
     <TD WIDTH="100%" ROWSPAN="2">
     <A HREF="[path_cgi]/info/[l->NAME]" STYLE="TEXT-DECORATION: NONE"><B>[l->NAME]@[l->host]</B></A>
     <BR>
     [l->subject]
     </TD></TR>
     <TR><TD>&nbsp;</TD></TR>
   [END]
</TABLE>
