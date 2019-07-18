package FollowUp::Common;


require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(isValidNumber replaceKeywords getDBcreds selectRandomTemplate timeStamp checkExcludedCarrier);

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";

my $log = Log::Log4perl->get_logger("followupEngine");

# should move all validation functions here

# validate the number
sub isValidNumber {
    my $number = shift;
    my $length = length($number);
    unless ( ($number =~ /\d+/) && ($length >= 10) && ($length <= 11) ) {
      return 0;
    }
    return 1;
}


sub selectRandomTemplate {
  my $didMatches = shift;
  my $random_key = 0;
  my @didMatchKeys = keys %{$didMatches};
  my $random_num = int(rand(@didMatchKeys));
  $random_key = $didMatchKeys[$random_num];
  $log->debug("DID matching returning $random_key");
  return $random_key;
}


# replace matching keywords
# need to enable a fallback like
# <--email;this and that--\>
sub replaceKeywords {
  my ($text,$leadData) = @_;
  $log->debug("replace in: $text");

  # cleanup
  if (defined $leadData->{'first_name'}) {
    $leadData->{'first_name'} = ucfirst(lc($leadData->{'first_name'}));
  }

  if (defined $leadData->{'last_name'}) {
      $leadData->{'last_name'} = ucfirst(lc($leadData->{'last_name'}));
  }

  # get all the matches.
  my @matches = $text =~ /<--([A-Za-z0-9_\-\s\:\+]+)-->/g;

  # lets search and replace them.
  foreach my $match (@matches) {

    # pick out keywords that have :: in them for var splitting.
    if ($match =~ /::/) {
      my ($key, $alt) = split(/::/, $match);
      my $regKey = "<--$match-->";

      # check for custom.
      if ($key =~ /^custom_(.*)$/) {
        my $custField = $1;
        if ($leadData->{'custom'}->{$custField}) {
          $text =~ s/$regKey/$leadData->{'custom'}->{$custField}/g;
        } else {
          # use alt data
          $text =~ s/$regKey/$alt/g;
        }
      }

      # process remainder
      if ($leadData->{$key}) {
        $text =~ s/$regKey/$leadData->{$key}/g;
      } else {
        # use alt data
        $text =~ s/$regKey/$alt/g;
      }
    } else {
      my $regKey = "<--$match-->";
      # check custom.
      if ($match =~ /^custom_(.*)$/) {
        my $custField = $1;
        $text =~ s/$regKey/$leadData->{'custom'}->{$custField}/g;
      } else {

        # do time matching.
        my $now = time;
        if ($match =~ /^\+(\d+)([a-z])/) {
          my $addTime = $1;
          my $addType = $2;

          # check for minutes
          if ($addType eq 'm') {
            $addTime = $addTime * 60;
          }
          # check for hours
          if ($addType eq 'h') {
            $addTime = $addTime * 60 * 60;
          }

          # now add up the time
          my $postNow = $now + $addTime;
          my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($postNow);
          $year = $year+1900;
          $mon = $mon+1;
          my $prettyTime = sprintf ( "%04d%02d%02d %02d:%02d:%02d", $year,$mon,$mday,$hour,$min,$sec);
          $text =~ s/\Q$regKey\E/$prettyTime/g;
          next;
        }

        # replace everything else.
        $text =~ s/$regKey/$leadData->{$match}/g;
      }
    }
  }

  $log->debug("replace out: $text");
  return $text;
}

sub getDBcreds {
  my $astConfig = shift;
  my $config = ();

  # parse the astgui config
  $log->debug("parsing astguiclient.conf");
  open(ASTCONF, "$astConfig") || die "can't open $astConfig: $!\n";
  my @conf = <ASTCONF>;
  close(ASTCONF);
  foreach my $line (@conf) {
    $line =~ s/ |>|\n|\r|\t|\#.*|;.*//gi;
    # database stuff
    if ($line =~ /^VARDB_server/) {
      $config->{'dbHost'} = $line;
      $config->{'dbHost'} =~ s/.*=//gi;
    }
    if ($line =~ /^VARDB_database/) {
      $config->{'dbName'} = $line;
      $config->{'dbName'} =~ s/.*=//gi;
    }
    if ($line =~ /^VARDB_user/) {
      $config->{'dbUser'} = $line;
      $config->{'dbUser'} =~ s/.*=//gi;
    }
    if ($line =~ /^VARDB_pass/) {
      $config->{'dbPass'} = $line;
      $config->{'dbPass'} =~ s/.*=//gi;
    }
  }
  return $config;
}


# timestamp function
sub timeStamp {
  # returns a timestamp for the file
  my $timestamp = ();
  my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime(time);
  $year = $year+1900;
  $mon = $mon+1;

  # various time usages
  $timestamp->{'file'} = sprintf ( "%04d%02d%02d-%02d.%02d.%02d", $year,$mon,$mday,$hour,$min,$sec);
  $timestamp->{'now'} = sprintf ( "%04d%02d%02d %02d:%02d:%02d", $year,$mon,$mday,$hour,$min,$sec);
  $timestamp->{'nowDate'} = sprintf ( "%04d%02d%02d", $year,$mon,$mday);
  $timestamp->{'nowMinute'} = sprintf ( "%02d", $min);
  $timestamp->{'nowHour'} = sprintf ( "%02d", $hour);

  # epoc
  $timestamp->{'epoc'} = time();

  # return our ref
    return $timestamp;
}

sub checkExcludedCarrier {
  my $excludedCarriers = shift;
  my $leadCarrier = shift;

  $log->debug("checking $excludedCarriers against $leadCarrier ");

  # multiple carrier entries.
  if ($excludedCarriers =~ /,/) {
    my @carrierExclude = split(/,/,$excludedCarriers);
    foreach my $eCarrier (@carrierExclude) {
      if ($leadCarrier =~ /$eCarrier/i) {
        return 1;
      }
    }
  }

  # handle single entries
  if ($leadCarrier =~ /$excludedCarriers/i) {
    return 1;
  }

  return 0;
}
