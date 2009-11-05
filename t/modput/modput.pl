#!/usr/bin/perl
use warnings;
use strict;

use GRID::Cluster;
use Data::Dumper;

my @machines = split(/:/, $ENV{GRID_REMOTE_MACHINES});

my ($debug, $max_num_np);

for (@machines) {
  $debug->{$_} = 0;
  $max_num_np->{$_} = 1;
}

my $cluster = GRID::Cluster->new(host_names => \@machines, debug => $debug, max_num_np => $max_num_np)
   || die "No machines has been initialized in the cluster";

my $result = $cluster->modput('Math::RPN');

$result = $cluster->eval(q{
              use Math::RPN;

               rpn(SERVER->logic_id, 1, '+');
            }
          );

print Dumper($result);
