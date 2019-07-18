package FollowUp::Config;


require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(getConfig);

use strict;
use warnings;
use FindBin qw($Bin $Script);
use lib "$Bin/../lib";
use Log::Log4perl qw(get_logger);
use Data::Validate::URI;
use List::MoreUtils qw(uniq);
use Email::Valid;
use Storable qw(nstore retrieve);
use FollowUp::Common;
use FollowUp::DB;
use Config::Simple;
use DBI;
use Time::Local;

# log file setup
my $log = Log::Log4perl->get_logger("followupEngine");

# parse astgui config
sub getConfig {

  # check and load config.
  my $config = checkConfig();

  # load astguiclient config
  $config->{'db'} = getDBcreds($config->{'astConfig'});

  my $dbh = DBI->connect(
    "DBI:mysql:database=$config->{'db'}->{'dbName'};host=$config->{'db'}->{'dbHost'}",
    $config->{'db'}->{'dbUser'},
    $config->{'db'}->{'dbPass'},
    {'RaiseError' => 1}
  );

  # we should check the schema version here and upgrade if needed
  checkSchemaUpdates($dbh, $config);

  # validate the internal db store
  $config->{'storeFile'} = "$Bin/../followupEngine.db";
  $log->debug("checking store file $config->{'storeFile'}");
  my $store=();
  if ( -f $config->{'storeFile'}) {
    $store = retrieve($config->{'storeFile'});
    unless ($store->{'lastRun'}) {
      $store->{'lastRun'} = 0;
    }
    $log->debug("loaded internal DB, runCount $store->{'runCount'}, last ran $store->{'lastRun'}")
  } else {
    # create new db
    $store->{'runCount'} = 0;
    nstore($store, $config->{'storeFile'});
  }

  # get the system settings from the db.
  my $settingsSQL = "select accountSID, accountToken, excludedStatuses, includedLists, apiUrl, runInterval, runWindow, excludedCarriers, testMode, testEmail, testPhone from ytel_settings limit 1;";
  $log->debug($settingsSQL);
  my $sth = $dbh->prepare($settingsSQL);
  $sth->execute();
  my $settingsConfig = $sth->fetchrow_hashref();
  $sth->finish();

  # merge the db with the loaded config
  $config = {%$config, %$settingsConfig};

  # load timestamp
  my $timeStamp = timeStamp();

  # run every x minutes, quit otherwise.
  if ($config->{'runInterval'}) {
    if ($store->{'lastRun'}) {
      my $timeDiff = $timeStamp->{'epoc'} - $store->{'lastRun'};
      my $runIntervalSeconds = $config->{'runInterval'} * 60;
      if ($timeDiff <= $runIntervalSeconds) {
        $log->debug("$timeStamp->{'epoc'} - $store->{'lastRun'} = $timeDiff <= $runIntervalSeconds in seconds");
        $log->info('interval not hit, shutting down.');
        exit;
      }
    }
  } else {
    $config->{'runInterval'} = 5;
  }

  # only run when in a window.
  # 8:00-17:30)
  if ($config->{'runWindow'}) {
    my ($start, $end) = split(/\-/,$config->{'runWindow'});
    # split out the value.
    my ($startHour, $startMin) = split(/:/, $start);
    my ($endHour, $endMin) = split(/:/, $end);

    # calculate epoc time
    my $now = time;
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
    my $startTime = timelocal(0, $startMin, $startHour, $mday, $mon, $year);
    my $endTime = timelocal(0, $endMin, $endHour, $mday, $mon, $year);

    unless ( $now > $startTime && $now < $endTime ) {
        $log->info("outside of the time window of $config->{'runWindow'}, shutting down");
        exit;
    }
  }


  # store the last run since we don't care about further exits.
  $store->{'lastRun'} = $timeStamp->{'epoc'};
  # store the db here for interval timing outside windows and what not.
  nstore($store, $config->{'storeFile'});


  # check for accountSID and or token.
  unless (($config->{'accountSID'}) && ($config->{'accountToken'}) && ($config->{'apiUrl'})) {
    $log->error("accountSID and/or accountToken and/or url missing, shutting down.");
    exit;
  }

  $config->{'apiUrl'} = "https://$config->{'accountSID'}:$config->{'accountToken'}\@$config->{'apiUrl'}";


  if ($config->{'testMode'}) {
    unless ($config->{'testEmail'}) {
      $config->{'testEmail'} = '';
    }
    unless ($config->{'testPhone'}) {
      $config->{'testPhone'} = 0;
    }
    $log->warn("we are in test mode, $config->{'testEmail'} and $config->{'testPhone'} will be the actual targets");
  }

  # load up a listid Array
  my @allListID;
  if ($config->{'includedLists'}) {
    my @listIDs = split(/,/,$config->{'includedLists'});
    @allListID = uniq @listIDs;
  }

  # load validation engine
  my $validate = Data::Validate::URI->new();

  # get all the templates
  my $templatesSQL = "select id, description, callCount, type, fromPrimary, fromAlternate, subject, body, bodyUrl, callbackUrl, includedStatuses, includedLists, includedCampaigns from ytel_followup_templates where active = 1;";
  $log->debug($templatesSQL);
  my $tempsth = $dbh->prepare($templatesSQL);
  $tempsth->execute();

  my @counts;
  my @lnpPhones;
  my $campaignCache = ();
  # cycle through the list.
  while (my $ref = $tempsth->fetchrow_hashref()) {
    my $id = $ref->{'id'};
    my $type = lc($ref->{'type'});
    my $callCount = $ref->{'callCount'};

    if ($ref->{'fromPrimary'}) {
      $ref->{'fromPrimary'} =~ s/\+//;
    }

    if ($ref->{'fromAlternate'}) {
      $ref->{'fromAlternate'} =~ s/\+//;
    }

    ## start validation
    # validate email
    if ($type =~ /^email/) {
      unless ($ref->{'body'}) {
        $log->info("template $id is missing a body");
      }
      unless ($ref->{'subject'}) {
        $log->info("template $id is missing a subject");
      }
      unless(Email::Valid->address($ref->{'fromPrimary'})) {
        $log->debug("template ID $id fromPrimary failed address check, results: $Email::Valid::Details");
        next;
      }
    }

    # sms validation
    if ($type =~ /sms/) {
      unless ((isValidNumber($ref->{'fromPrimary'}) && ($ref->{'body'}))) {
        $log->debug("from phone, or body incorrect.");
        next;
      }
      push(@lnpPhones,$ref->{'fromPrimary'});
    }

    # rvm validation
    if ($type =~ /rvm/) {
      # validate primary
      unless (isValidNumber($ref->{'fromPrimary'})) {
        $log->debug("from primary phone is incorrect");
        next;
      }

      # validate alt
      unless (isValidNumber($ref->{'fromAlternate'})) {
        $log->debug("from alternate phone is incorrect.");
        next;
      }

      # validate urls
      unless ($validate->is_uri($ref->{'bodyUrl'})) {
        next;
      }
      push(@lnpPhones,$ref->{'fromPrimary'});
    }

    # validate the callback
    if ($ref->{'callbackUrl'}) {
      unless ($validate->is_uri($ref->{'callbackUrl'})) {
        next;
      }
    }
    ## end validation

    # store the template
    $config->{'templates'}->{$callCount}->{$type}->{$id} = $ref;
    $config->{'templates'}->{$callCount}->{$type}->{$id}->{'type'} = $type;

    # lets handle the included lists, and campaignID, they are appended to eachother
    my @listIDs;
    if ($ref->{'includedLists'}) {
      @listIDs = split(/,/,$ref->{'includedLists'});
    }

    if ($ref->{'includedCampaigns'}) {
      my @newList = fetchCampaignLists($dbh,$ref->{'includedCampaigns'});
      push(@listIDs, @newList);
    }
    @listIDs = uniq @listIDs;
    $config->{'templates'}->{$callCount}->{$type}->{$id}->{'includedLists'} = join ',', @listIDs;

    # push the listIDs
    push(@allListID, @listIDs);

    # push the call count
    push(@counts, $callCount);
  }
  $tempsth->finish();

  $config->{'dbh'} = $dbh;

  # generate the lnp for later
  @lnpPhones = uniq @lnpPhones;
  my $lnpCount = @lnpPhones;
  if ($lnpCount) {
    $config->{'templateDIDs'} = join ',', @lnpPhones;
  }


  # generate the call count string
  my @cCounts = uniq @counts;
  @cCounts = sort @cCounts;
  my $count = @cCounts;
  if ($count) {
    $config->{'callCounts'} = join ',', @cCounts;
  } else {
    $config->{'callCounts'} = 0;
  }

  # do the listID stuff
  @allListID = uniq @allListID;
  @allListID = sort @allListID;
  my $listIdCount = @allListID;
  if ($listIdCount) {
    $config->{'includedLists'} = join ',', @allListID;
  }

  return $config;
}

# checks the current config against the dist config and upgrades it.
sub checkConfig {

  my $baseConfigFile = "$Bin/../etc/settings.conf.default";
  my $configFile = "$Bin/../etc/settings.conf";

  unless (-e $configFile) {
    $log->warn('missing config, creating default');
    my $defaultConfig = "$configFile\.default";
    `cp $defaultConfig $configFile`;
  }

  # load base config.
  my $cfgBase = new Config::Simple($baseConfigFile);
  my $baseConfig = $cfgBase->get_block('followUpEngine');

  # load current config.
  my $cfg = new Config::Simple($configFile);
  my $config = $cfg->get_block('followUpEngine');

  # now go through the base, and validate it exists in the config
  my $configChange = 0;
  foreach my $configKey (keys %{$baseConfig}) {
    unless ($config->{$configKey}) {
      $configChange=1;
      $config->{$configKey} = $baseConfig->{$configKey};
      $log->info("config $configKey added");
    }
  }

  if ($configChange) {
    $cfg->set_block('followUpEngine', $config);
    $cfg->save();
    $log->info("wrote updated config");
  }
  return $config;
}

# get the campaign id for the list.
sub fetchCampaignLists {
  my $dbh = shift;
  my $campID = shift;
  $log->debug("retrieving lists for $campID campaign.");
  my $campSQL = qq( select list_id from vicidial_lists where campaign_id = '$campID' and active = 'Y'; );
  my $sth = $dbh->prepare($campSQL);
  $sth->execute();
  my @lists;
  while (my $ref = $sth->fetchrow_hashref()) {
    $log->debug("including list $ref->{'list_id'}");
    push(@lists,$ref->{'list_id'});
  }
  return @lists;
}
