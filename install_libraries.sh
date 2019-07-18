#!/bin/bash

echo "installing perl modules";
cpanm $1 \
AnyEvent \
AnyEvent::Fork::Pool \
Log::Log4perl \
HTTP::Request::Common \
LWP::UserAgent \
Email::Valid \
Data::Validate::URI \
LWP::Protocol::https \
List::MoreUtils \
Array::Utils \
Config::Simple \
NetAddr::IP \
HTTP::Tiny \
JSON \
URI::Encode \
IO::Socket::SSL

mkdir -p /var/log/followUpEngine
