package FollowUp::DB;


require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(checkSchemaUpdates);

use strict;
use warnings;
use FindBin qw($Bin $Script);
use lib "$Bin/../lib";
use Log::Log4perl qw(get_logger);
use DBI;
use Storable qw(nstore retrieve);
use FollowUp::Common;

# schema version
my $schema=7;

# logging
my $log = Log::Log4perl->get_logger("followupEngine");

# check for schema updates
sub checkSchemaUpdates {
  my $dbh = shift;
  my $config = shift;

  $log->info("script version 3.$schema");

  $log->debug('checking table structure');

  # get the schema for version 0 before we had all this
  my $tableSQL = qq( show tables like 'ytel_\%settings' );
  $log->debug($tableSQL);
  my $tableSTH = $dbh->prepare($tableSQL);
  $tableSTH->execute();
  my $settingsTable = 0;
  while (my $row = $tableSTH->fetchrow_arrayref) {
    my $name = $row->[0];
    # skip this table.
    if ($name eq 'ytel_settings') {
      $settingsTable=1;
    }

    if ($name eq 'ytel_followup_settings') {
      upgradeSchema($dbh, 0);
      return;
    }

  }

  # we have a no tables, so we should insert the base
  unless ($settingsTable) {
    insertSchema($config);
    return;
  }


  $log->debug('fetching schema version');
  # fetch the schema version if we are using the right settings table
  my $dbSchemaSQL = qq( select dbSchema from ytel_settings limit 1;);
  $log->debug($dbSchemaSQL);
  my $schemaSTH = $dbh->prepare($dbSchemaSQL);
  $schemaSTH->execute();
  while (my $row = $schemaSTH->fetchrow_arrayref) {
    my $dbSchema = $row->[0];
    if ($dbSchema < $schema) {
      upgradeSchema($dbh, $dbSchema);
      return;
    }
  }
}

sub insertSchema {
  my $config = shift;
  $log->info("new install creating tables");
  my $schemaFile = "$Bin/../schema/base.sql";
  my $db = $config->{'db'};
  my $output = `cat $schemaFile | mysql -h $db->{'dbHost'} -u $db->{'dbUser'} -p$db->{'dbPass'} $db->{'dbName'}`;
  $log->info("tables created");
}


sub getConfigID {
  my $dbh = shift;
  my $ver = shift;

  # check if there is a record in the right tables, if not lets insert one.
  my $dbSchemaSQL = qq( select id from ytel_settings limit 1;);
  unless ($ver) {
    $dbSchemaSQL = qq( select id from ytel_followup_settings limit 1;);
  }

  $log->debug($dbSchemaSQL);
  my $schemaSTH = $dbh->prepare($dbSchemaSQL);
  $schemaSTH->execute();
  my $id = 0;
  while (my $row = $schemaSTH->fetchrow_arrayref) {
    $id = $row->[0];
  }
  $log->debug("settings ID: $id");
  return $id;
}


# need to redo this as we may not have a config to update.
sub upgradeSchema {
  my $dbh = shift;
  my $oldSchema = shift;
  my $oldSchemaCount = $oldSchema;

  $log->info("beginning schema upgrade from $oldSchema to $schema");

  # get config id
  my $id = getConfigID($dbh, $oldSchema);

  # insert the first config record if none exist.
  unless ($id) {
    my $dbInsertSchema = 'insert into ytel_followup_settings set apiURL = "https://api.ytel.com";';
    if ($oldSchema) {
      $dbInsertSchema = 'insert into ytel_settings set dbSchema = 0;';
    }
    $log->debug($dbInsertSchema);
    $dbh->do($dbInsertSchema);

    # get the new ID
    $id = getConfigID($dbh, $oldSchema);
  }

  # upgrade loop
  while ($oldSchemaCount < $schema) {
    $oldSchemaCount++;
    # read the schema file
    my $schemaFile = "$Bin/../schema/$oldSchemaCount.sql";
    open(my $schemaFH, '<:encoding(UTF-8)', $schemaFile) or die "Could not open file '$schemaFile' $!";
    while (my $sqlQuery = <$schemaFH>) {
      chomp $sqlQuery;
      $log->debug($sqlQuery);
      $dbh->do($sqlQuery);
    }

    my $schemaSQL = "UPDATE ytel_settings set dbSchema = $oldSchemaCount where id = $id";
    $log->debug($schemaSQL);
    $dbh->do($schemaSQL);
  }


  resetLNPstore();
  $log->info("upgraded $oldSchema to $schema");
}


sub resetLNPstore {
    my $storeFile = "$Bin/../followupEngine.db";
    if (-e $storeFile) {
      $log->info("purging lnp data from $storeFile");
      my $store = retrieve($storeFile);
      delete $store->{'lnp'};
      nstore($store, $storeFile);
    }
}
