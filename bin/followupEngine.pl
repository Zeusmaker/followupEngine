#!/usr/bin/perl
# uses the Ytel API to send SMS, RVM, email, api
# based on call counts, statuses, included lists, and campaigns.

# version 3.7
use warnings;
use strict;
use DBI;
use HTTP::Tiny;
use Data::Dumper;
use JSON;
use Email::Valid;
use Data::Validate::URI;
use Storable qw(nstore retrieve);
use Fcntl qw(:flock);
use AnyEvent;
use AnyEvent::Fork;
use AnyEvent::Fork::Pool;
use Log::Log4perl;
use Array::Utils qw(:all);
use FindBin qw($Bin);
use lib "$Bin/../lib";
use FollowUp::Config;
use FollowUp::Common;


my $lockfile = '/tmp/followupEngine.lock';
open(my $fhpid, '>', $lockfile) or die "error: open '$lockfile': $!";
flock($fhpid, LOCK_EX|LOCK_NB) or die "already running";

# log file setup
Log::Log4perl->init("$Bin/../etc/log.conf");
my $log = Log::Log4perl->get_logger("followupEngine");

$log->info("starting followupEngine");

# load the config
my $config = getConfig();

unless ($config->{'callCounts'}) {
  $log->warn("no call counts configured");
  exit;
}
$log->info("loaded $config->{'callCounts'} call counts");

## database connections
my $dbh = $config->{'dbh'};
# load internal db
my $store = retrieve($config->{'storeFile'});

# lnp dip our own numbers for matching purposes.
if ($config->{'templateDIDs'}) {
  my @lnpPhones = split(/,/,$config->{'templateDIDs'});
  LNPDip(1,@lnpPhones);
}

## HTTP worker pools
# build the post worker pool
my $urlPostPool = AnyEvent::Fork
   ->new
   ->require ("FollowUp::UrlWorker")
   ->AnyEvent::Fork::Pool::run (
        "FollowUp::UrlWorker::runPost", # the worker function

        # pool management
        max        => 10,   # absolute maximum # of processes
        idle       => 2,   # minimum # of idle processes
        load       => 2,   # queue at most this number of jobs per process
        start      => 0.1, # wait this many seconds before starting a new process
        stop       => 10,  # wait this many seconds before stopping an idle process
        on_destroy => (my $finish = AE::cv), # called when object is destroyed

        # parameters passed to AnyEvent::Fork::RPC
        async      => 0,
        on_error   => sub { die "FATAL: $_[0]\n" },
        on_event   => sub { my @ev = @_ },
     );

# build the get worker pool
my $urlGetPool = AnyEvent::Fork
  ->new
  ->require ("FollowUp::UrlWorker")
  ->AnyEvent::Fork::Pool::run (
       "FollowUp::UrlWorker::runGet", # the worker function

       # pool management
       max        => 10,   # absolute maximum # of processes
       idle       => 2,   # minimum # of idle processes
       load       => 2,   # queue at most this number of jobs per process
       start      => 0.1, # wait this many seconds before starting a new process
       stop       => 10,  # wait this many seconds before stopping an idle process
       on_destroy => (my $gFinish = AE::cv), # called when object is destroyed

       # parameters passed to AnyEvent::Fork::RPC
       async      => 0,
       on_error   => sub { die "FATAL: $_[0]\n" },
       on_event   => sub { my @ev = @_ },
    );

# process all outbound stuff.
processOutbound();

# sleeping for 10 seconds before we fire everything off, just to give the chance for a queue to load.
sleep 5;

# close the pools
undef $urlPostPool;
undef $urlGetPool;

# wait for them to finish.
$finish->recv;
$gFinish->recv;

# store last run
my $timeStamp = timeStamp();
$store->{'runCount'}++;
$store->{'lastRun'} = $timeStamp->{'epoc'};

# store the internal DB
nstore($store, $config->{'storeFile'});

$log->info("completed $store->{'runCount'} run since last reset");

exit;


### functions

## start of outbound call check.
sub processOutbound {

  # load up all calls for today.
  my $callList = getRecentCalls();
  unless ($callList) {
    $log->info("nothing to do, quiting.");
    return;
  }

  # Main loop of actions for found leads
  foreach my $leadID (keys %{ $callList } ) {
    # cycle through the call counts for
    my $leadData = $callList->{$leadID};
    my $callCount = $leadData->{'called_count'};

    # cycle through the templates for this call count, since we could send more than one.
    my $countTemplates = $config->{'templates'}->{$callCount};
    foreach my $templateType  (keys %{ $countTemplates }) {

      # get a random template from the template call count array.
      my $templateID = getRandomTemplate($leadData, $templateType);
      my $template = $countTemplates->{$templateType}->{$templateID};

      # check the template status against lead status
      if ($template->{'includedStatuses'}) {
        my $leadStatus = $callList->{$leadID}->{'status'};
        unless ($template->{'includedStatuses'} =~ /\b$leadStatus\b/) {
          $log->debug("$leadID with a status of $leadStatus is not in templates statuses: $template->{'includedLists'}");
          next;
        }
      }

      # check the template included lists against the lead list id
      if ($template->{'includedLists'}) {
        my $leadListID = $callList->{$leadID}->{'list_id'};
        unless ($template->{'includedLists'} =~ /\b$leadListID\b/) {
          $log->debug("$leadID with a listID of $leadListID is not in templates lists: $template->{'includedLists'}");
          next;
        }
      }

      # check if the type, and count matches something we've done already
      if (getPostStatus($leadData, $templateType)) {
        $log->debug("$templateType, $callCount, $leadID was already posted");
        next;
      }

      # post the template to get sent.
      sendTemplate($template, $leadData);
    } # end of the template search
  } # lead loop
}

# load a job into the queue for posts
sub queuePostUrl {
  my ($url, $postData, $leadData, $template) = @_;

  # shorthand
  my $callCount = $leadData->{'called_count'};
  my $leadID = $leadData->{'lead_id'};

  $log->debug("Queueing $leadID for $template->{'type'}");

  # encode the data
  my $jsonData = encode_json $postData;
  $urlPostPool->($url, $jsonData, sub {
    my ($response) = @_;
    $log->debug("worker responded with: $response");
    if ($response) {
      storeResponse($leadData, $template, $jsonData, $response);
    }  else {
      $log->error("failed to make request");
    }
  });

}

# load a job into the queue for get
sub queueGetUrl {
  my ($url, $leadData, $template) = @_;

  # shorthand
  my $callCount = $leadData->{'called_count'};
  my $leadID = $leadData->{'lead_id'};

  $log->debug("Queueing $leadID for $template->{'type'}");

  $urlGetPool->($url, sub {
    my ($response) = @_;
    $log->debug("worker responded with: $response");
    if ($response) {
      storeResponse($leadData, $template, $url, $response);
    }
  });

}

# send an email
sub sendTemplate {
  my ($template, $leadData) = @_;

  # shorthand
  my $callCount = $leadData->{'called_count'};
  my $leadID = $leadData->{'lead_id'};

  $log->info("Sending $template->{'type'} for $leadID at call count $template->{'callCount'}");

  # match the template and send it
  if ($template->{'type'} eq 'rvm') {
    my $toPhone = $leadData->{'phone_number'};
    unless ($store->{'lnp'}->{$toPhone}->{'Wireless'}) {
      storeResponse($leadData, $template, $toPhone, 'not wireless');
      return;
    }
    sendRVM($template, $leadData);
  } elsif ($template->{'type'} eq 'sms') {
    my $toPhone = $leadData->{'phone_number'};

    # ignore if not wireless.
    unless ($store->{'lnp'}->{$toPhone}->{'Wireless'}) {
      $log->debug("lnp for $toPhone is not wireless");
      storeResponse($leadData, $template, $toPhone, 'not wireless');
      return;
    }

    # exclude sms based on global setting and carrier.
    if ($config->{'excludedCarriers'}) {
      my $leadCarrier = $store->{'lnp'}->{$toPhone}->{'Network'};
      my $excludedCarrier = $config->{'excludedCarriers'};
      if (checkExcludedCarrier($excludedCarrier,$leadCarrier)) {
        $log->debug("$toPhone with carrier $leadCarrier, matched $excludedCarrier");
        storeResponse($leadData, $template, $toPhone, "$leadCarrier is excluded");
        return;
      }
    }


    sendSMS($template, $leadData);
  } elsif ($template->{'type'} =~ '^email') {
    sendEmail($template, $leadData);
  } elsif ($template->{'type'} =~ 'api') {
    sendAPI($template, $leadData);
  } else {
    $log->debug("no matching template type $template->{'type'} for call count: $template->{'callCount'}");
  }
  return;
}

# send an email
sub sendEmail {
  my ($template, $leadData) = @_;

  # shorthand
  my $callCount = $leadData->{'called_count'};
  my $leadID = $leadData->{'lead_id'};

  $log->debug("[sendEmail] $template->{'callCount'}, $leadID");

  # override it.
  my $oldType = $template->{'type'};
  $template->{'type'} = 'email';

  # validation checks
  unless ($leadData->{'email'}) {
    $log->debug("no email address for lead.");
    storeResponse($leadData, $template, $leadData->{'email'}, 'no email');
    return;
  } else {
    # return if its an invalid email address
    unless(Email::Valid->address($leadData->{'email'})) {
      $log->debug("address failed $Email::Valid::Details check.");
      storeResponse($leadData, $template, $leadData->{'email'}, $Email::Valid::Details);
      return;
    }
  }

  my $postData = ();
  $postData->{'from'} = $template->{'fromPrimary'};
  if ($template->{'fromAlternate'}) {
    $postData->{'fromname'} = $template->{'fromAlternate'};
  }

  $postData->{'to'} = $leadData->{'email'};
  $postData->{'message'} = replaceKeywords($template->{'body'}, $leadData);
  $postData->{'subject'} = replaceKeywords($template->{'subject'}, $leadData);
  if ($oldType eq "email") {
    $postData->{'type'} = 'text';
  } else {
    $postData->{'type'} = 'html';
  }
  $postData->{'MessageStatusCallback'} = $template->{'callbackUrl'};
  my $url = $config->{'apiUrl'}.$config->{'emailUrl'};
  queuePostUrl($url, $postData, $leadData, $template);

}

# send an rvm
sub sendRVM {
  my ($template, $leadData) = @_;
  my $toPhone = $leadData->{'phone_number'};
  unless (isValidNumber($toPhone)) {
    $log->debug("no phone number");
    storeResponse($leadData, $template, $toPhone, 'no number');
    return 0;
  }
  my $postData = ();
  $postData->{'from'} = $template->{'fromPrimary'};
  $postData->{'RVMCallerId'} = $template->{'fromAlternate'};
  $postData->{'to'} = $leadData->{'phone_number'};
  $postData->{'VoiceMailUrl'} = $template->{'bodyUrl'};
  $postData->{'MessageStatusCallback'} = $template->{'callbackUrl'};
  my $url = $config->{'apiUrl'}.$config->{'rvmUrl'};
  # queue it
  queuePostUrl($url, $postData, $leadData, $template);
  # store the sticky in the local db
  storeSticky($template->{'fromPrimary'}, $toPhone);
  return;
}

# store sticky if needed
sub storeSticky {
  my $from = shift;
  my $to = shift;
  if (defined $store->{'sticky'}->{$to}) {
    if ($store->{'sticky'}->{$to} != $from) {
      $log->debug("sticky changed from $store->{'sticky'}->{$to} to $from for lead phone $to");
      $store->{'sticky'}->{$to} = $from;
    }
  } else {
    $log->debug("storing sticky $from for lead $to");
    $store->{'sticky'}->{$to} = $from
  }
}

# send an generic api request
# need to split out the urls and post them one at a time.
sub sendAPI {
  my ($template, $leadData) = @_;
  # shorthand
  my $callCount = $leadData->{'called_count'};
  my $leadID = $leadData->{'lead_id'};

  $log->debug("[sendAPI] $template->{'callCount'}, $leadID");

  my $urlType = 'get';
  # check to see if we have a post type
  if (defined $template->{'subject'}) {
    $urlType = lc($template->{'subject'});
  }

  # check to see if its multi url.
  my @urls;
  if ($template->{'bodyUrl'} =~ /\|/) {
    $log->debug('found a multi URL api request, extracting URLs');
    my @split = split(/\|/, $template->{'bodyUrl'});
    push(@urls, @split);
  } else {
    push (@urls, $template->{'bodyUrl'});
  }

  # go through the urls and queue them.
  foreach my $uri (@urls) {
    $log->debug("processing $urlType for $uri");

    # if its post lets do this.
    if ($urlType eq "post") {
      my $postData = ();
      # merge the arrays
      %$postData = (%$leadData, %$template);
      queuePostUrl($template->{'bodyUrl'}, $postData, $leadData, $template);
    } else {
      # send get otherwise
      my $url = replaceKeywords($template->{'bodyUrl'}, $leadData);
      queueGetUrl($url, $leadData, $template);
    }
  }
}

# send an sms
sub sendSMS {
  my ($template, $leadData) = @_;

  my $toPhone = $leadData->{'phone_number'};

  unless (isValidNumber($toPhone)) {
    $log->debug("no phone number");
    storeResponse($leadData, $template, $toPhone, 'no number');
    return 0;
  }
  my $postData = ();
  $postData->{'from'} = $template->{'fromPrimary'};
  $postData->{'to'} = $toPhone;
  $postData->{'body'} = replaceKeywords($template->{'body'}, $leadData);
  $postData->{'MessageStatusCallback'} = $template->{'callbackUrl'};
  my $url = $config->{'apiUrl'}.$config->{'smsUrl'};
  queuePostUrl($url, $postData, $leadData, $template);
  # store the sticky in the local db
  storeSticky($template->{'fromPrimary'}, $toPhone);
  return;
}

# store the lnp response with a timestamp
sub storeLNP {
  my $phone = shift;
  my $lnpData = shift;

  $lnpData->{'ts'} = time;

  # set the wireless to an int.
  if ($lnpData->{'Wireless'} eq 'true') {
    $lnpData->{'Wireless'} = 1;
  } else {
    $lnpData->{'Wireless'} = 0;
  }

  $log->debug("stored lnp for $phone as wireless = $lnpData->{'Wireless'}");
  $store->{'lnp'}->{$phone} = $lnpData;
}

# load recent outbound calls from now.
sub getRecentCalls {
  $log->info("fetching recent calls");
  # get lists of calls in live-agents
  my $live = ();
  my $liveSQL = "select distinct(lead_id) from vicidial_live_agents where status = 'INCALL';";
  $log->debug($liveSQL);
  my $livesth = $dbh->prepare($liveSQL);
  $livesth->execute();

  # cycle through the list.
  while (my $ref = $livesth->fetchrow_hashref()) {
    $live->{$ref->{'lead_id'}} = 1;
  }
  $livesth->finish();

  # we should a get an array of all custom tables so we can use them if needed.
  my $customTables = ();
  my $tablesSQL = "show tables like 'custom%';";
  my $tablesth = $dbh->prepare($tablesSQL);
  $tablesth->execute();
  while (my $ref = $tablesth->fetchrow_array()) {
  	$customTables->{$ref} = 1;
  }
  $tablesth->finish();


  # get call counts
  my $calls = ();

  # filter by call counts
  my $callCountList = '';
  if ($config->{'callCounts'}) {
    $callCountList = "and vicidial_list.called_count in ($config->{'callCounts'})";
  } else {
    $log->info("no call counts configured");
    exit;
  }

  # check if the included lists is blank or not.
  my $includedList = '';
  if ($config->{'includedLists'}) {
    $includedList = "and vicidial_list.list_id in ($config->{'includedLists'})";
  }

  my $excludedStatus = "and status not in ('DNC','DNCL')";
  if ($config->{'excludedStatuses'}) {
    $excludedStatus = "and status not in ('DNC','DNCL',$config->{'excludedStatuses'})";
  }

  my $backTime = $config->{'runInterval'} + 5;
  my $callsSQL = "select lead_id,list_id,phone_number,email,first_name,last_name,address1,address2,address3,city,state,postal_code,called_count,status,entry_list_id from vicidial_list where modify_date >= DATE_SUB(NOW(), INTERVAL $backTime minute) $includedList $excludedStatus $callCountList;";
  $log->debug($callsSQL);
  my $sth = $dbh->prepare($callsSQL);
  $sth->execute();

  my $count = 0;
  my @lnpPhones;
  my $campaignList = ();
  # cycle through the list.
  while (my $ref = $sth->fetchrow_hashref()) {
    my $leadID = $ref->{'lead_id'};
    my $listID = $ref->{'list_id'};

    # skip if its in the live lead table, or if there is no template for that call count.
    if ($live->{$leadID}) {
      $log->debug("lead $leadID is in an active call skipping");
      next;
    }

    # store the full array
    $calls->{$leadID} = $ref;

    # lets get the campaign id for this list, and cache it if needed.
    unless (defined $campaignList->{$listID}) {
      $campaignList->{$listID} = getCampaignID($listID);
    }
    $calls->{$leadID}->{'campaign_id'} = $campaignList->{$listID};

    # get the last outbound callerID used
    $calls->{$leadID}->{'outboundCID'} = getDialCID($leadID);

    # lets gather any custom data for this lead
    if ($customTables->{"custom_$listID"}) {
      my $customData = getCustomData($listID, $leadID);
      if (!$customData && $ref->{'entry_list_id'}) {
        $customData = getCustomData($ref->{'entry_list_id'}, $leadID);
      }
      $calls->{$leadID}->{'custom'} = $customData;
    }

    $count++;

    # check for test mode
    if ($config->{'testMode'}) {
      $calls->{$leadID}->{'phone_number'}    =    $config->{'testPhone'};
      $calls->{$leadID}->{'email'}    =    $config->{'testEmail'};
      push(@lnpPhones, $calls->{$leadID}->{'phone_number'});
    } else {
      push(@lnpPhones, $ref->{'phone_number'});
    }
  }
  $sth->finish();

  # lets lnp dip them all
  my $lnpCount = @lnpPhones;
  if ($lnpCount) {
    LNPDip(0,@lnpPhones);
  }

  $log->info("found $count leads to send");
  return $calls;
}

# check the lead against the log to make sure we don't hit them again.
sub getPostStatus {
  my ($leadData, $templateType) = @_;

  # shorthand
  my $callCount = $leadData->{'called_count'};
  my $leadID = $leadData->{'lead_id'};

  # email is special
  if ($templateType =~ /^email.*/) {
    if ($templateType ne 'email') {
      $templateType = 'email';
    }
  }

  my $statusSQL = qq( select count(leadID) as count from ytel_followup_log where leadID = $leadID and templateType = '$templateType' and callCount = $callCount; );
  my $sth = $dbh->prepare($statusSQL);
  $sth->execute();
  my $ref = $sth->fetchrow_hashref();
  return $ref->{'count'};
}

# store the Response
# we should insert the full $callList->{$leadID}, and full template
# data in json format.
sub storeResponse {
  my ($leadData, $template, $request, $response) = @_;

  # shorthand
  my $leadID = $leadData->{'lead_id'};

  my $postSQL = 'INSERT INTO ytel_followup_log (leadID, templateType, callCount, templateData, leadData, request, response) VALUES (?, ?, ?, ?, ?, ?, ?);';
  $log->debug("storing Response: $postSQL");
  $log->debug($postSQL);
  my $sth = $dbh->prepare($postSQL);

  # convert to json
  my $templateJSON = encode_json $template;
  my $leadJSON = encode_json $leadData;

  $sth->execute($leadID, $template->{'type'}, $template->{'callCount'}, $templateJSON, $leadJSON, $request, $response);
}

# get the campaign id for the list.
sub getCampaignID {
  my $listID = shift;
  my $campSQL = qq( select campaign_id from vicidial_lists where list_id = $listID limit 1; );
  $log->debug("getCampaignID: $campSQL");
  my $sth = $dbh->prepare($campSQL);
  $sth->execute();
  my $campID = '';
  while (my $ref = $sth->fetchrow_hashref()) {
    $campID = $ref->{'campaign_id'};
  }
  return $campID;
}

# get the campaign id for the list.
sub getDialCID {
  my $leadID = shift;
  my $backTime = $config->{'runInterval'} + 3600;
  my $dialCidSQL = qq( select MID(vicidial_dial_log.outbound_cid, 25, 10) as cid from vicidial_dial_log where lead_id = $leadID and call_date >= DATE_SUB(NOW(), INTERVAL $backTime minute) order by call_date DESC limit 1; );
  $log->debug("getDialCID: $dialCidSQL");
  my $sth = $dbh->prepare($dialCidSQL);
  $sth->execute();
  my $cid = 0;
  while (my $ref = $sth->fetchrow_hashref()) {
    $cid = $ref->{'cid'};
  }
  if ($cid) {
    $log->debug("found outbound CID of $cid");
  } else {
    $log->debug("no cid found, possible modified lead");
  }
  return $cid;
}

# get the custom field data for this lead
sub getCustomData {
  my $listID = shift;
  my $leadID = shift;
  my $tablesSQL = "select * from custom_$listID where lead_id = $leadID limit 1;";
  my $tablesth = $dbh->prepare($tablesSQL);
  $tablesth->execute();
  my $customData = $tablesth->fetchall_arrayref({});
	$customData = $customData->[0];
  return $customData;
}


# tries to do a did match on the lead, and the numbers it has available for that call count.
# will attempt to use a previously used number for sticky purposes
# otherwise will did match.
# otherwise it will pick one at random if there is no match
sub getRandomTemplate {
  my $leadData = shift;
  my $templateType = shift;

  # shorthand
  my $callCount = $leadData->{'called_count'};
  my $leadID = $leadData->{'lead_id'};

  # short the template
  my $templates = $config->{'templates'}->{$callCount}->{$templateType};

  # if the type is one below, we should try to did match.
  if ($templateType eq 'sms' || $templateType eq 'rvm') {
    my $leadPhone = $leadData->{'phone_number'};

    # extract area code.
    my $leadAreaCode = substr($leadPhone, 0, 3);

    my $didMatches = ();

    # check all templates for different matches
    my $outboundCID = $leadData->{'outboundCID'};
    foreach my $tID (keys %{ $templates }) {
      my $fromPrimary = $templates->{$tID}->{'fromPrimary'};

      # check to see if there is an outbound cid match
      if ($outboundCID == $fromPrimary) {
        $didMatches->{'outboundCID'}->{$tID} = 1;
      }

      # look for a sticky did
      if (defined $store->{'sticky'}->{$leadPhone}) {
        if ($store->{'sticky'}->{$leadPhone} == $fromPrimary) {
          $log->debug("found sticky DID for $leadPhone using $fromPrimary with ID $tID");
          $didMatches->{'sticky'} = $tID;
        }
      }

      # attempt a DID match
      $log->debug("checking template $tID with phone $fromPrimary to lead $leadPhone");
      my $tAreaCode = substr($fromPrimary, 0, 3);
      if ($tAreaCode == $leadAreaCode) {
        $log->debug("DID areacode match for $leadPhone adding $fromPrimary");
        $didMatches->{'areacode'}->{$tID} = 1;
      }

      # attempt zipcode match
      my @leadARR = @{$store->{'lnp'}->{$leadPhone}->{'Zips'}};
      my @templateArr = @{$store->{'lnp'}->{$fromPrimary}->{'Zips'}};
      my @zipList = intersect( @templateArr, @leadARR );
      my $zipCount = @zipList;
      if ($zipCount) {
        $log->debug("DID zipcode match for $leadPhone adding $fromPrimary with $zipCount zipcodes");
        $didMatches->{'zipcode'}->{$tID} = 1;
      }


      # attempt state match
      if ($store->{'lnp'}->{$leadPhone}->{'State'} eq $store->{'lnp'}->{$fromPrimary}->{'State'}) {
        $log->debug("DID state match for $leadPhone adding $fromPrimary for state $store->{'lnp'}->{$fromPrimary}->{'State'}");
        $didMatches->{'State'}->{$tID} = 1;
      }

    }

    ## setup did matching stuff here
    $log->debug("finding best match");

    # outboundCID
    if ($didMatches->{'outboundCID'}) {
      my $random_key = selectRandomTemplate($didMatches->{'outboundCID'});
      $log->debug("outbound CID matching returning $random_key");
      return $random_key;
    }

    # sticky
    if ($didMatches->{'sticky'}) {
      return $didMatches->{'sticky'};
    }

    # get random areacode
    if ($didMatches->{'areacode'}) {
      my $random_key = selectRandomTemplate($didMatches->{'areacode'});
      $log->debug("areacode matching returning $random_key");
      return $random_key;
    }

    # zipcode matching
    if ($didMatches->{'zipcode'}) {
      my $random_key = selectRandomTemplate($didMatches->{'zipcode'});
      $log->debug("zipcode matching returning $random_key");
      return $random_key;
    }

    # state matching
    if ($didMatches->{'State'}) {
      my $random_key = selectRandomTemplate($didMatches->{'State'});
      $log->debug("State matching returning $random_key");
      return $random_key;
    }

  }

  # default random template
  my $random_key = selectRandomTemplate($templates);
  $log->debug("random template returning $random_key");
  return $random_key;
}

# dips a whole list
sub LNPDip {
  my ($internal, @phones) = @_;
  my $lnpCount = @phones;
  $log->info("LNP Dipper starting on $lnpCount numbers");

  # build the url fetching worker pool
  my $pool = AnyEvent::Fork
     ->new
     ->require ("FollowUp::UrlWorker")
     ->AnyEvent::Fork::Pool::run (
          "FollowUp::UrlWorker::runPost", # the worker function

          # pool management
          max        => 10,   # absolute maximum # of processes
          idle       => 0,   # minimum # of idle processes
          load       => 2,   # queue at most this number of jobs per process
          start      => 0.1, # wait this many seconds before starting a new process
          stop       => 10,  # wait this many seconds before stopping an idle process
          on_destroy => (my $finish = AE::cv), # called when object is destroyed

          # parameters passed to AnyEvent::Fork::RPC
          async      => 0,
          on_error   => sub { die "FATAL: $_[0]\n" },
          on_event   => sub { my @ev = @_ },
          serialiser => $AnyEvent::Fork::RPC::STRING_SERIALISER,
       );

   # get the current time.
   for my $phone (@phones) {

     # validate cache expiration
     if ($store->{'lnp'}->{$phone}->{'ts'}) {
       # # if its our number ignore the expire.
       if ($internal) {
         $log->debug("$phone is an internal number, skipping future lnp updates.");
         next;
       }
       my $nowTime = time;
       my $lnpDiff =  $nowTime - $store->{'lnp'}->{$phone}->{'ts'};
       $log->debug("last lnp diff for $phone is $lnpDiff");
       unless ($lnpDiff > $config->{'lnpExpire'}) {
         next;
       }
     }

     my $url = $config->{'apiUrl'}.$config->{'carrierUrl'};
     $log->debug("queuing $phone for dipping | $url");

     my $postData->{'phonenumber'} = $phone;
     my $jsonData = encode_json $postData;

     # send the request to the pool
     $pool->($url, $jsonData, sub {
      my ($response) = @_;
      $log->debug("worker responded with: $response");
      if ($response) {
        my $decodedResponse  = decode_json $response;
        my $lnpData = $decodedResponse->{'Message360'}->{'Carrier'};
        storeLNP($phone, $lnpData);
      } else {
        $log->error("failed to lookup $phone");
      }
     });

   }

   undef $pool;
   $finish->recv;
   nstore($store, $config->{'storeFile'});
}
