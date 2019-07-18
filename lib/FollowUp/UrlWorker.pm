package FollowUp::UrlWorker;

use strict;
use warnings;
use HTTP::Tiny;
use URI::Encode qw(uri_encode uri_decode);
use JSON;

sub runPost {
  my ($url, $jsonData) = @_;
  $url = uri_encode($url);
  my $responseData = ();
  my $postData = decode_json $jsonData;
  my $http = HTTP::Tiny->new();
  my $response = $http->post_form($url, $postData);
  if ($response->{'success'}) {
    $responseData->{'content'} = $response->{'content'};
    $responseData->{'url'} = $url;
    return $response->{'content'};
  } else {
   return 0;
  }
}

sub runGet {
  my ($url) = @_;
  $url = uri_encode($url);
  my $http = HTTP::Tiny->new();
  my $response = $http->get($url);
  if ($response->{'success'}) {
   return $response->{'content'};
  } else {
   return 0;
  }
}

1;
