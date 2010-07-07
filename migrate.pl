#!/usr/bin/perl -w

# migrate.pl, Version 0.2.0
# Migrate GnuCash SQLite data to a Moneydance XML file.
# Only queries are done from the database.
# Output is to standard out.
#
# Developed using:
#  o  Moneydance Version 751
#  o  Mac OS X 10.6.3
#  o  GnuCash 2.3.14
#  o  SQLite3 
#  o  Perl 5.8.9
#  o  p5-dbd-sqlite modules current in macports as of development date.
#
# Usage:
#  perl migrate.pl > my_finances.xml
#  Then, in Moneydance: File, Open, my_finances.xml
#
# Original Author: Sid Reed (sreed@flash.net)
# Author of 0.2.x: Eric Simmerman (www.ericsimmerman.com)
# Original Date:   31 July 2005
# Original Rev:    1 Aug 2005 - Removed routine to fix check numbers.
# 0.2.x Rev:    13 June 2010 - Complete overhaul to port script for use with 
#			  GnuCash SQLite storage (Postgre support was dropped from GnuCash)
#
# Portions Copyright (c) 2005, Sid Reed
# Portions Copyright (c) 2010, Eric Simmerman
# 
# ================================================
# This program is free software: you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   Yor a copy of the GNU General Public License, see <http://www.gnu.org/licenses/>.
# ================================================
#
# Pre-requisites:
#  o  Perl and its modules DBD and DBD::SQLite installed and
#     operational - I use macports to install p5-dbd-sqlite
#  o  The GnuCash file must have been saved into SQLite format. At the time of this release
#			this requires the latest *unstable* release of GnuCash.
#  o  The user running this program must have access to read this GnuCash SQLite database.
#
#
# Limitations:
#  o  As written, this program preserves the subaccount
#     relationship up to four levels deep, so you can have
#        Assets:Investments:Retirement:Stock
#     but NOT
#        Assets:Investments:Retirement:Stock:SmallCap
#     because the SmallCap subaccount is too deep.
#  o  None of the business or investment account functionality
#     of GnuCash was tested or used.  It might work, but
#     probably won't.
#  o  No memorized transactions are built.

use DBI;

my $accountcode;       # Accountcode, from GnuCash
my $accountname;       # Accountname, from GnuCash (name after final colon)
my $amount;            # Transaction/split amount
my $date_entered;      # Date_entered, from GnuCash
my $date_posted;       # Date_posted, from GnuCash
my $description;       # Transaction description
my $first = 1;         # Logic aid - first account to print in subaccounts
my $ggp_acct;          # Great-grandparent accountname
my $gp_acct;           # Grandparent accountname
my $i;                 # Loop counter
my $lastlevel = 0;     # Keep track of indentation in account output
my $level = 0;         # Keep track of indentation in account output
my $memo;              # Transaction memo, from GnuCash
my $num;               # Value in the transaction num field from GnuCash
my $p_acct;            # Parent accountname
my $reconciled;        # Transaction status, translated from GnuCash
my $splitcount;        # Number of splits in a transaction
my $transguid;         # Transguid, from GnuCash
my $trans_id = 100;    # Moneydance TXNID, start at 100

#DBI->trace(1);

if($#ARGV + 1 != 1){
	die "\nYou must supply the name of the GNUCash SQLite file as the only argument!\nUsage: migrate.pl [gnucash-sqlite-filename]\n\n";
}

# Connecting
$dbh=DBI->connect("dbi:SQLite:dbname=".$ARGV[0], "", "", {
                  PrintError => 0,   ### Don't report errors via warn(  )
                  RaiseError => 1    ### Do report errors via die(  )
                  } ) or
             die "can't connect: $!\n";

#
# So far, so good.  Begin the output.
#

#
# Duplicate a Moneydance XML file up to the Accounts section.
#

create_header();

#
# Obtain the GnuCash Chart of Accounts.
# All of the GnuCash accounts must have accountcodes assigned, or
# this program cannot do the transaction splits correctly.
# As written, this query preserves the subaccount relationship
# up to four levels deep, so you can have
#   Assets:Investments:Retirement:Stock
# but NOT
#   Assets:Investments:Retirement:Stock:SmallCap.
# Account types are translated to Moneydance types.
#

$sql_a=qq{select a.rowid,
                 case a.account_type
                   when 'EXPENSE' then 'E'
                   when 'INCOME' then 'I'
                   when 'ASSET' then 'A'
                   when 'EQUITY' then 'Y'
 				   when 'RECEIVABLE' then 'A'
                   when 'BANK' then 'B'
                   when 'CASH' then 'A'
                   when 'LIABILITY' then 'Y'
				   when 'PAYABLE' then 'Y'
                   when 'STOCK' then 'S'
                   when 'MUTUAL' then 'S'
                   when 'CREDIT' then 'C'
                   else a.account_type
                 end,
                 a.name,
                 b.name,c.name,d.name  
            from accounts as a 
left outer join accounts as b on b.guid = a.parent_guid 
left outer join accounts as c on c.guid = b.parent_guid
left outer join accounts as d on d.guid = c.parent_guid
		   where a.account_type != 'ROOT'
           order by 1};

$sth_a=$dbh->prepare("$sql_a") or
                die "Cannot prepare $sql_a\n";

$sth_a->execute or
         die "Cannot execute $sql_a\n";

#
# Retrieve chart of accounts data and print it.
#

while (@row = $sth_a->fetchrow_array)
{
  if (!defined($row[0]))
  {
     die "All accounts must have the accountcode set in GnuCash.\n";
  }

  if (defined $row[3] && $row[3] ne 'Root Account')
  {
    $p_acct = $row[3];
    $level = 1;

    if (defined $row[4]  && $row[4] ne 'Root Account')
    {
      $gp_acct = $row[4];
      $level = 2;

      if (defined $row[5]  && $row[5] ne 'Root Account')
      {
        $ggp_acct = $row[5];
        $level = 3;
      }
      else
      {
        $ggp_acct = "";
      }
    }
    else
    {
      $ggp_acct = "";
      $gp_acct = "";
    }
  }
  else
  {
    $ggp_acct = "";
    $gp_acct = "";
    $p_acct = "";
    $level = 0;
  }

  if ($level > $lastlevel)
  {
    print "  " x $level . "  <SUBACCOUNTS>\n";
  }
  elsif ($level == $lastlevel)
  {
    if ($first == 0)
    {
      print "  " x ($level + 1) . " </ACCOUNT>\n";
    }
    else
    {
      print "  <SUBACCOUNTS>\n";
      $first = 0;
    }
  }
  elsif ($level < $lastlevel)
  {
    for ($i = $lastlevel; $i > $level; $i--)
    {
      print "  " x ($i + 1) . " </ACCOUNT>\n";
      print "  " x ($i + 1) . "</SUBACCOUNTS>\n";
    }

    print "  " x ($i + 1) . " </ACCOUNT>\n";
  }

  print "  " x $level . "   <ACCOUNT>\n";
  print "  " x $level . "    <TYPE>$row[1]</TYPE>\n";
  print "  " x $level . "    <NAME>$row[2]</NAME>\n";
  print "  " x $level . "    <ACCTID>$row[0]</ACCTID>\n";
  print "  " x $level . "    <CURRID>2</CURRID>\n";
  print "  " x $level . "    <STARTBAL>0.00</STARTBAL>\n";
  print "  " x $level . "    <ACCTPARAMS>\n";
  print "  " x $level . "     <PARAM>\n";
  print "  " x $level . "      <KEY>ui_two_lines</KEY>\n";

  # Display two lines if it's a Bank account, otherwise only one.
  print "  " x $level . "      <VAL>n</VAL>\n" if ($row[1] !~ "B");
  print "  " x $level . "      <VAL>y</VAL>\n" if ($row[1] =~ "B");

  print "  " x $level . "     </PARAM>\n";
  print "  " x $level . "     <PARAM>\n";
  print "  " x $level . "      <KEY>ui_sort_order</KEY>\n";
  print "  " x $level . "      <VAL>0</VAL>\n";
  print "  " x $level . "     </PARAM>\n";
  print "  " x $level . "     <PARAM>\n";
  print "  " x $level . "      <KEY>ui_sort_ascending</KEY>\n";
  print "  " x $level . "      <VAL>y</VAL>\n";
  print "  " x $level . "     </PARAM>\n";
  print "  " x $level . "    </ACCTPARAMS>\n";

  $lastlevel = $level;
}

for ($i = $lastlevel; $i >= 0; $i--)
{
  print "  " x ($i + 1) . " </ACCOUNT>\n";
  print "  " x ($i + 1) . "</SUBACCOUNTS>\n";
}

print "  " x ($i + 1) . " </ACCOUNT>\n";

#
# My GnuCash data had unbalanced transactions - a transaction with
# only one split.  The HAVING clause in this query filtered those out.
#
# This query forms the basis of the transaction output loop.
#
# A separate query obtains the split information for each
# transaction.
#

$sql_p=qq{SELECT t.guid as transguid, count(s.guid) as splitcount
            FROM transactions t, splits s
           WHERE s.tx_guid = t.guid
           GROUP BY t.guid
          HAVING count(s.guid) > 1};

$sth_p=$dbh->prepare("$sql_p") or
                die "Cannot prepare $sql_p\n";

$sth_p->execute or
         die "Cannot execute $sql_p\n";

#
# This is the query for each split of a transaction.
#

$sql_s=qq{SELECT t.post_date,
                 t.enter_date,
                 t.num,
                 t.description,
                 s.memo,
                 a.rowid,
                 a.name,
                 case s.reconcile_state
                  when 'n' then ' '
                  when 'c' then 'x'
                  when 'y' then 'X'
                 end,                 
                 case a.account_type
                   when 'EQUITY' then ROUND((s.value_num / -100.0), 2)
                   else ROUND((s.value_num / 100.0), 2)
                 end
            FROM accounts as a, splits as s, transactions as t
           WHERE a.guid = s.account_guid
             AND s.tx_guid = t.guid
             AND t.guid = ?
           ORDER BY s.value_num, a.code};

$sth_s=$dbh->prepare("$sql_s") or
                die "Cannot prepare $sql_s\n";

#
# Output the transactions and their splits.
#

print " <TXNS>\n";

while (($transguid, $splitcount) = $sth_p->fetchrow_array)
{
   $sth_s->execute($transguid) or
           die "Cannot execute $sql_s\n";

   # Use the first split as the parent transaction.

   if (($date_posted,
        $date_entered,
        $num,
        $description,
        $memo,
        $accountcode,
        $accountname,
        $reconciled,
        $amount) = $sth_s->fetchrow_array)
  {
    # Moneydance uses date formats of the form "2005.10.27 15:10:32:371"

    $date_entered =~ m/(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/;
	$date_entered = $1.".".$2.".".$3." ".$4.":".$5.":".$6;
    $date_posted =~ m/(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/;	
    $date_posted = $1.".".$2.".".$3." ".$4.":".$5.":".$6;


    #
    # Print the parent transaction.
    #

    parent_trans($trans_id,
                 $splitcount,
                 $date_posted,
                 $date_entered,
                 $num,
                 $description,
                 $memo,
                 $accountcode,
                 $accountname,
                 $reconciled);

    #
    # Print the split(s) for the parent transaction.
    #

    while (($date_posted,
            $date_entered,
            $num,
            $description,
            $memo,
            $accountcode,
            $accountname,
            $reconciled,
            $amount) = $sth_s->fetchrow_array)
    {
      #
      # Build Moneydance Transaction Number on the fly.
      #

      $trans_id += 1;

      #
      # Print a split.
      #

      split_trans($trans_id,
                  $description,
                  $memo,
                  $accountcode,
                  $reconciled,
                  $amount);
    }

    print "   </SPLITS>\n";
    print "  </PTXN>\n";
    $trans_id += 1;       # Because the parent used a trans_id, too.
  }
}

print " </TXNS>\n";

#
# Put the final touches on the XML output.
#

create_trailer();

$sth_a->finish;
$sth_p->finish;
$sth_s->finish;
undef $sth_a;
undef $sth_p;
undef $sth_s;
$dbh->disconnect
    or warn "Disconnection failed: $DBI::errstr\n";

############# END OF PROGRAM ####################

############## SUBROUTINES ######################

#
# Print a parent transaction.
#

sub parent_trans
{
  my $top_trans_id = shift;
  my $n_splits = shift;
  my $p_date_posted = shift;
  my $p_date_entered = shift;
  my $p_num = shift;
  my $p_description = shift;
  my $p_memo = shift;
  my $p_accountcode = shift;
  my $p_accountname = shift;
  my $p_reconciled = shift;

  my $p_trans_id = $top_trans_id + $n_splits;

  if ($p_date_entered !~ /:\d\d\d/)
  {
    $p_date_entered .= ":000";
  }

  print "  <PTXN>\n";
  print "   <TXNID>$p_trans_id</TXNID>\n";
  print "   <ACCTID>$p_accountcode</ACCTID>\n";
  print "   <DESC>$p_description</DESC>\n";
  print "   <STATUS>$p_reconciled</STATUS>\n";
  print "   <DATE>$p_date_posted</DATE>\n";
  print "   <DTENTERED>$p_date_entered</DTENTERED>\n";
  print "   <TAXDATE>$p_date_posted</TAXDATE>\n";
  print "   <CHECKNUM>$p_num</CHECKNUM>\n";
  print "   <MEMO>$p_memo</MEMO>\n";
  print "   <TAGS>\n";
  print "   </TAGS>\n";
  print "   <SPLITS>\n";
}

#
# Print a transaction split.
#

sub split_trans
{
  my $s_trans_id = shift;
  my $s_description = shift;
  my $s_memo = shift;
  my $s_accountcode = shift;
  my $s_reconciled = shift;
  my $s_amount = shift;

  # Remove spaces from amounts, so the math will work.
  $s_amount =~ s/ //g;

  my $parent_amount = -1 * $s_amount;

  print "    <STXN>\n";
  print "     <TXNID>$s_trans_id</TXNID>\n";
  print "     <ACCTID>$s_accountcode</ACCTID>\n";
  print "     <DESC>$s_description</DESC>\n";
  printf("     <PARENTAMT>%.2f</PARENTAMT>\n", $parent_amount);
  printf("     <SPLITAMT>%.2f</SPLITAMT>\n", $s_amount);
  print "     <RAWRATE>1</RAWRATE>\n";
  print "     <STATUS>$s_reconciled</STATUS>\n";
  print "     <TAGS>\n";
  print "     </TAGS>\n";
  print "    </STXN>\n";
}

#
# Print a copy of the top part of a Moneydance XML file.
#

sub create_header
{
  print '<?xml version="1.0" encoding="UTF-8"?>' . "\n";
  print '<!DOCTYPE mdxml1>' . "\n";
  print '<MONEYDANCEDATA>' . "\n";
  print ' <CURRENCYLIST>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>2</CURRID>' . "\n";
  print '   <CURRCODE>USD</CURRCODE>' . "\n";
  print '   <NAME>US Dollar</NAME>' . "\n";
  print '   <RAWRATE>1</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>$</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>64</CURRID>' . "\n";
  print '   <CURRCODE>ZMK</CURRCODE>' . "\n";
  print '   <NAME>Zambian Kwacha</NAME>' . "\n";
  print '   <RAWRATE>28.80184332</RAWRATE>' . "\n";
  print '   <DECPLACES>0</DECPLACES>' . "\n";
  print '   <PREFIX>ZK</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>63</CURRID>' . "\n";
  print '   <CURRCODE>VEB</CURRCODE>' . "\n";
  print '   <NAME>Venezuelan Bolivar</NAME>' . "\n";
  print '   <RAWRATE>745.15648286</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>Bs</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>60</CURRID>' . "\n";
  print '   <CURRCODE>TRL</CURRCODE>' . "\n";
  print '   <NAME>Turkish Lira</NAME>' . "\n";
  print '   <RAWRATE>15974.4408946</RAWRATE>' . "\n";
  print '   <DECPLACES>0</DECPLACES>' . "\n";
  print '   <PREFIX></PREFIX>' . "\n";
  print '   <SUFFIX>TL</SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>61</CURRID>' . "\n";
  print '   <CURRCODE>TTD</CURRCODE>' . "\n";
  print '   <NAME>Trinidad and Tobago Dollar</NAME>' . "\n";
  print '   <RAWRATE>6.06060606</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>TT$</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>59</CURRID>' . "\n";
  print '   <CURRCODE>THB</CURRCODE>' . "\n";
  print '   <NAME>Thai Baht</NAME>' . "\n";
  print '   <RAWRATE>44.72271914</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>Bt</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>62</CURRID>' . "\n";
  print '   <CURRCODE>TWD</CURRCODE>' . "\n";
  print '   <NAME>Taiwan Dollars</NAME>' . "\n";
  print '   <RAWRATE>34.54231434</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>NT$</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>23</CURRID>' . "\n";
  print '   <CURRCODE>CHF</CURRCODE>' . "\n";
  print '   <NAME>Swiss Francs</NAME>' . "\n";
  print '   <RAWRATE>1.63105529</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>CHF</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>57</CURRID>' . "\n";
  print '   <CURRCODE>SEK</CURRCODE>' . "\n";
  print '   <NAME>Swedish Krona</NAME>' . "\n";
  print '   <RAWRATE>10.56859015</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX></PREFIX>' . "\n";
  print '   <SUFFIX>kr</SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>56</CURRID>' . "\n";
  print '   <CURRCODE>SDD</CURRCODE>' . "\n";
  print '   <NAME>Sudan Pound</NAME>' . "\n";
  print '   <RAWRATE>256.01638505</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>Pound</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>31</CURRID>' . "\n";
  print '   <CURRCODE>ESP</CURRCODE>' . "\n";
  print '   <NAME>Spanish Peseta</NAME>' . "\n";
  print '   <RAWRATE>184.36578171</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX></PREFIX>' . "\n";
  print '   <SUFFIX>Ptas</SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>16</CURRID>' . "\n";
  print '   <CURRCODE>KRW</CURRCODE>' . "\n";
  print '   <NAME>South Korean Won</NAME>' . "\n";
  print '   <RAWRATE>12.96680498</RAWRATE>' . "\n";
  print '   <DECPLACES>0</DECPLACES>' . "\n";
  print '   <PREFIX></PREFIX>' . "\n";
  print '   <SUFFIX>W</SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>13</CURRID>' . "\n";
  print '   <CURRCODE>ZAR</CURRCODE>' . "\n";
  print '   <NAME>South African Rand</NAME>' . "\n";
  print '   <RAWRATE>9.53288847</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>R</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>58</CURRID>' . "\n";
  print '   <CURRCODE>SGD</CURRCODE>' . "\n";
  print '   <NAME>Singapore Dollars</NAME>' . "\n";
  print '   <RAWRATE>1.82348651</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>S$</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>55</CURRID>' . "\n";
  print '   <CURRCODE>SAR</CURRCODE>' . "\n";
  print '   <NAME>Saudi \'Arabian\' Riyal</NAME>' . "\n";
  print '   <RAWRATE>3.75093773</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>SR</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>54</CURRID>' . "\n";
  print '   <CURRCODE>ROL</CURRCODE>' . "\n";
  print '   <NAME>Romanian Leu</NAME>' . "\n";
  print '   <RAWRATE>32154.340836</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX></PREFIX>' . "\n";
  print '   <SUFFIX>lei</SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>53</CURRID>' . "\n";
  print '   <CURRCODE>PTE</CURRCODE>' . "\n";
  print '   <NAME>Portugese Escudo</NAME>' . "\n";
  print '   <RAWRATE>2.22123501</RAWRATE>' . "\n";
  print '   <DECPLACES>0</DECPLACES>' . "\n";
  print '   <PREFIX></PREFIX>' . "\n";
  print '   <SUFFIX>Esc</SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>52</CURRID>' . "\n";
  print '   <CURRCODE>PLN</CURRCODE>' . "\n";
  print '   <NAME>Polish Zloty</NAME>' . "\n";
  print '   <RAWRATE>4.2462845</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX></PREFIX>' . "\n";
  print '   <SUFFIX>zl</SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>50</CURRID>' . "\n";
  print '   <CURRCODE>PHP</CURRCODE>' . "\n";
  print '   <NAME>Philippines Peso</NAME>' . "\n";
  print '   <RAWRATE>52.00208008</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>P</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>51</CURRID>' . "\n";
  print '   <CURRCODE>PKR</CURRCODE>' . "\n";
  print '   <NAME>Pakistani Rupee</NAME>' . "\n";
  print '   <RAWRATE>64.1025641</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>Rs</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>14</CURRID>' . "\n";
  print '   <CURRCODE>NOK</CURRCODE>' . "\n";
  print '   <NAME>Norwegian Kroner</NAME>' . "\n";
  print '   <RAWRATE>8.82612533</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>kr.</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>15</CURRID>' . "\n";
  print '   <CURRCODE>KPW</CURRCODE>' . "\n";
  print '   <NAME>North Korean Won</NAME>' . "\n";
  print '   <RAWRATE>2.20022002</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX></PREFIX>' . "\n";
  print '   <SUFFIX>Wn</SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>49</CURRID>' . "\n";
  print '   <CURRCODE>NZD</CURRCODE>' . "\n";
  print '   <NAME>New Zealand Dollar</NAME>' . "\n";
  print '   <RAWRATE>2.41254524</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>NZ$</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>46</CURRID>' . "\n";
  print '   <CURRCODE>MXN</CURRCODE>' . "\n";
  print '   <NAME>Mexican Pesos</NAME>' . "\n";
  print '   <RAWRATE>10.6797</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>$</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>47</CURRID>' . "\n";
  print '   <CURRCODE>MYR</CURRCODE>' . "\n";
  print '   <NAME>Malaysian Ringgit</NAME>' . "\n";
  print '   <RAWRATE>3.80228137</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>RM</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>45</CURRID>' . "\n";
  print '   <CURRCODE>LUF</CURRCODE>' . "\n";
  print '   <NAME>Luxembourg Franc</NAME>' . "\n";
  print '   <RAWRATE>0.44702727</RAWRATE>' . "\n";
  print '   <DECPLACES>0</DECPLACES>' . "\n";
  print '   <PREFIX>LuxF</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>44</CURRID>' . "\n";
  print '   <CURRCODE>LBP</CURRCODE>' . "\n";
  print '   <NAME>Lebanese Pound</NAME>' . "\n";
  print '   <RAWRATE>15.19064256</RAWRATE>' . "\n";
  print '   <DECPLACES>0</DECPLACES>' . "\n";
  print '   <PREFIX></PREFIX>' . "\n";
  print '   <SUFFIX>L.L.</SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>43</CURRID>' . "\n";
  print '   <CURRCODE>JOD</CURRCODE>' . "\n";
  print '   <NAME>Jordonian Dollar</NAME>' . "\n";
  print '   <RAWRATE>7.1438777</RAWRATE>' . "\n";
  print '   <DECPLACES>3</DECPLACES>' . "\n";
  print '   <PREFIX>JD</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>11</CURRID>' . "\n";
  print '   <CURRCODE>JPY</CURRCODE>' . "\n";
  print '   <NAME>Japanese Yen</NAME>' . "\n";
  print '   <RAWRATE>1.21728545</RAWRATE>' . "\n";
  print '   <DECPLACES>0</DECPLACES>' . "\n";
  print '   <PREFIX>&#165;</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>42</CURRID>' . "\n";
  print '   <CURRCODE>JMD</CURRCODE>' . "\n";
  print '   <NAME>Jamaican Dollar</NAME>' . "\n";
  print '   <RAWRATE>49.26108374</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>J$</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>5</CURRID>' . "\n";
  print '   <CURRCODE>ITL</CURRCODE>' . "\n";
  print '   <NAME>Italian Lira</NAME>' . "\n";
  print '   <RAWRATE>21.45462347</RAWRATE>' . "\n";
  print '   <DECPLACES>0</DECPLACES>' . "\n";
  print '   <PREFIX>L.</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>39</CURRID>' . "\n";
  print '   <CURRCODE>ILS</CURRCODE>' . "\n";
  print '   <NAME>Israeli New Shekel</NAME>' . "\n";
  print '   <RAWRATE>4.27350427</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX></PREFIX>' . "\n";
  print '   <SUFFIX>NIS</SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>38</CURRID>' . "\n";
  print '   <CURRCODE>IEP</CURRCODE>' . "\n";
  print '   <NAME>Irish Punt</NAME>' . "\n";
  print '   <RAWRATE>0.8726765</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>IRB#</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>37</CURRID>' . "\n";
  print '   <CURRCODE>IDR</CURRCODE>' . "\n";
  print '   <NAME>Indonesian Rupiah</NAME>' . "\n";
  print '   <RAWRATE>107.03200257</RAWRATE>' . "\n";
  print '   <DECPLACES>0</DECPLACES>' . "\n";
  print '   <PREFIX>Rp</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>40</CURRID>' . "\n";
  print '   <CURRCODE>INR</CURRCODE>' . "\n";
  print '   <NAME>Indian Rupee</NAME>' . "\n";
  print '   <RAWRATE>48.07692308</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>Rs</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>41</CURRID>' . "\n";
  print '   <CURRCODE>ISK</CURRCODE>' . "\n";
  print '   <NAME>Icelandic Krona</NAME>' . "\n";
  print '   <RAWRATE>104.54783063</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX></PREFIX>' . "\n";
  print '   <SUFFIX>IKr</SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>36</CURRID>' . "\n";
  print '   <CURRCODE>HUF</CURRCODE>' . "\n";
  print '   <NAME>Hungarian Forint</NAME>' . "\n";
  print '   <RAWRATE>2.82167043</RAWRATE>' . "\n";
  print '   <DECPLACES>0</DECPLACES>' . "\n";
  print '   <PREFIX></PREFIX>' . "\n";
  print '   <SUFFIX>Ft</SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>35</CURRID>' . "\n";
  print '   <CURRCODE>HKD</CURRCODE>' . "\n";
  print '   <NAME>Hong Kong Dollar</NAME>' . "\n";
  print '   <RAWRATE>7.80031201</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>HK$</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>34</CURRID>' . "\n";
  print '   <CURRCODE>GRD</CURRCODE>' . "\n";
  print '   <NAME>Greek Drachma</NAME>' . "\n";
  print '   <RAWRATE>377.50094375</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX></PREFIX>' . "\n";
  print '   <SUFFIX>Dr</SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>6</CURRID>' . "\n";
  print '   <CURRCODE>DEM</CURRCODE>' . "\n";
  print '   <NAME>German Mark</NAME>' . "\n";
  print '   <RAWRATE>2.16731686</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX></PREFIX>' . "\n";
  print '   <SUFFIX>DM</SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>9</CURRID>' . "\n";
  print '   <CURRCODE>FRF</CURRCODE>' . "\n";
  print '   <NAME>French Franc</NAME>' . "\n";
  print '   <RAWRATE>7.26744186</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX></PREFIX>' . "\n";
  print '   <SUFFIX>F</SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>32</CURRID>' . "\n";
  print '   <CURRCODE>FIM</CURRCODE>' . "\n";
  print '   <NAME>Finnish Markka</NAME>' . "\n";
  print '   <RAWRATE>6.58761528</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX></PREFIX>' . "\n";
  print '   <SUFFIX>FMk</SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>33</CURRID>' . "\n";
  print '   <CURRCODE>FJD</CURRCODE>' . "\n";
  print '   <NAME>Fijian Dollar</NAME>' . "\n";
  print '   <RAWRATE>2.30255584</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>F$</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>7</CURRID>' . "\n";
  print '   <CURRCODE>EUR</CURRCODE>' . "\n";
  print '   <NAME>Euro</NAME>' . "\n";
  print '   <RAWRATE>1.10803324</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>&#8364;</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>30</CURRID>' . "\n";
  print '   <CURRCODE>EGP</CURRCODE>' . "\n";
  print '   <NAME>Egyption Pound</NAME>' . "\n";
  print '   <RAWRATE>4.28449015</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>L.E.</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>48</CURRID>' . "\n";
  print '   <CURRCODE>NLG</CURRCODE>' . "\n";
  print '   <NAME>Dutch Gilder</NAME>' . "\n";
  print '   <RAWRATE>2.44200244</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>f.</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>28</CURRID>' . "\n";
  print '   <CURRCODE>DKK</CURRCODE>' . "\n";
  print '   <NAME>Danish Kroner</NAME>' . "\n";
  print '   <RAWRATE>8.25082508</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>Dkr</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>8</CURRID>' . "\n";
  print '   <CURRCODE>DKK</CURRCODE>' . "\n";
  print '   <NAME>Danish Krone</NAME>' . "\n";
  print '   <RAWRATE>8.25082508</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>kr</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>26</CURRID>' . "\n";
  print '   <CURRCODE>CZK</CURRCODE>' . "\n";
  print '   <NAME>Czech Koruna</NAME>' . "\n";
  print '   <RAWRATE>37.09198813</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX></PREFIX>' . "\n";
  print '   <SUFFIX>Kc</SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>27</CURRID>' . "\n";
  print '   <CURRCODE>CYP</CURRCODE>' . "\n";
  print '   <NAME>Cyprus Pound</NAME>' . "\n";
  print '   <RAWRATE>0.61774154</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>B#C</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>25</CURRID>' . "\n";
  print '   <CURRCODE>CNY</CURRCODE>' . "\n";
  print '   <NAME>Chinese \'Yuan\' Renmimbi</NAME>' . "\n";
  print '   <RAWRATE>8.28500414</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>Y</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>24</CURRID>' . "\n";
  print '   <CURRCODE>CLP</CURRCODE>' . "\n";
  print '   <NAME>Chilean Pesos</NAME>' . "\n";
  print '   <RAWRATE>737.46312684</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>Ch$</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>4</CURRID>' . "\n";
  print '   <CURRCODE>CAD</CURRCODE>' . "\n";
  print '   <NAME>Canadian Dollar</NAME>' . "\n";
  print '   <RAWRATE>1.59184973</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>$</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>20</CURRID>' . "\n";
  print '   <CURRCODE>BGN</CURRCODE>' . "\n";
  print '   <NAME>Bulgarian Lev</NAME>' . "\n";
  print '   <RAWRATE>0.02155637</RAWRATE>' . "\n";
  print '   <DECPLACES>0</DECPLACES>' . "\n";
  print '   <PREFIX></PREFIX>' . "\n";
  print '   <SUFFIX>lv</SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>10</CURRID>' . "\n";
  print '   <CURRCODE>GBP</CURRCODE>' . "\n";
  print '   <NAME>British Pound</NAME>' . "\n";
  print '   <RAWRATE>0.68427535</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>&#163;</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>12</CURRID>' . "\n";
  print '   <CURRCODE>BRL</CURRCODE>' . "\n";
  print '   <NAME>Brazilian Real</NAME>' . "\n";
  print '   <RAWRATE>2.76014353</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>R$</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>21</CURRID>' . "\n";
  print '   <CURRCODE>BMD</CURRCODE>' . "\n";
  print '   <NAME>Bermudian Dollar</NAME>' . "\n";
  print '   <RAWRATE>0.99000099</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>Bd$</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>19</CURRID>' . "\n";
  print '   <CURRCODE>BEF</CURRCODE>' . "\n";
  print '   <NAME>Belgian Franc</NAME>' . "\n";
  print '   <RAWRATE>44.70272687</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX></PREFIX>' . "\n";
  print '   <SUFFIX>BF</SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>18</CURRID>' . "\n";
  print '   <CURRCODE>BBD</CURRCODE>' . "\n";
  print '   <NAME>Barbados Dollar</NAME>' . "\n";
  print '   <RAWRATE>1.99004975</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX></PREFIX>' . "\n";
  print '   <SUFFIX>Bds$</SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>22</CURRID>' . "\n";
  print '   <CURRCODE>BSD</CURRCODE>' . "\n";
  print '   <NAME>Bahamian Dollar</NAME>' . "\n";
  print '   <RAWRATE>1</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>B$</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>17</CURRID>' . "\n";
  print '   <CURRCODE>ATS</CURRCODE>' . "\n";
  print '   <NAME>Austrian Schilling</NAME>' . "\n";
  print '   <RAWRATE>15.24622656</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>S</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>3</CURRID>' . "\n";
  print '   <CURRCODE>AUD</CURRCODE>' . "\n";
  print '   <NAME>Australian Dollar</NAME>' . "\n";
  print '   <RAWRATE>1.96618168</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>A$</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print '  <CURRENCY>' . "\n";
  print '   <CURRID>29</CURRID>' . "\n";
  print '   <CURRCODE>DZD</CURRCODE>' . "\n";
  print '   <NAME>Algerian Dinar</NAME>' . "\n";
  print '   <RAWRATE>80.12820513</RAWRATE>' . "\n";
  print '   <DECPLACES>2</DECPLACES>' . "\n";
  print '   <PREFIX>DA</PREFIX>' . "\n";
  print '   <SUFFIX></SUFFIX>' . "\n";
  print '   <TICKER></TICKER>' . "\n";
  print '   <EFFECTVDATE>2005.07.27</EFFECTVDATE>' . "\n";
  print '   <CURRTYPE>0</CURRTYPE>' . "\n";
  print '   <CURRHIST>' . "\n";
  print '   </CURRHIST>' . "\n";
  print '   <CURRSPLITS>' . "\n";
  print '   </CURRSPLITS>' . "\n";
  print '   <TAGS>' . "\n";
  print '   </TAGS>' . "\n";
  print '  </CURRENCY>' . "\n";
  print ' </CURRENCYLIST>' . "\n";
  print ' <ACCOUNT>' . "\n";
  print '  <TYPE>R</TYPE>' . "\n";
  print '  <NAME>My Finances</NAME>' . "\n";
  print '  <ACCTID>0</ACCTID>' . "\n";
  print '  <CURRID>2</CURRID>' . "\n";
  print '  <STARTBAL>0.00</STARTBAL>' . "\n";
  print '  <ACCTPARAMS>' . "\n";
  print '   <PARAM>' . "\n";
  print '    <KEY>addressbook</KEY>' . "\n";
  print '    <VAL>{&#10;  "entries" = (&#10; )&#10;&#10;}&#10;</VAL>' . "\n";
  print '   </PARAM>' . "\n";
  print '   <PARAM>' . "\n";
  print '    <KEY>BACKUP_LAST_DATE</KEY>' . "\n";
  print '    <VAL>1122471156313</VAL>' . "\n";
  print '   </PARAM>' . "\n";
  print '   <PARAM>' . "\n";
  print '    <KEY>newtxncount</KEY>' . "\n";
  print '    <VAL>8</VAL>' . "\n";
  print '   </PARAM>' . "\n";
  print '  </ACCTPARAMS>' . "\n";
}  # create_header()

#
# Print a copy of the last little bit of a Moneydance XML file.
#

sub create_trailer
{
  print " <REMINDERS>\n";
  print " </REMINDERS>\n";
  print " <ONLINEINFO>{&#10;}&#10;</ONLINEINFO>\n";
  print "</MONEYDANCEDATA>\n";
}  # create_trailer
