package GRID::Cluster;

use strict;
use warnings;

use GRID::Machine;
use GRID::Cluster::Result;
use GRID::Cluster::Handle;
use IO::Select;
use List::Util qw(sum);

# Size of the buffer which is used to read from
# remote processes
use constant BUFFERSIZE => 2048;

our $VERSION = '0.03';

# Constructor

sub new {
  my $class = shift;
  my %opts = @_;

  my $self;
  if (exists($opts{config}) && -r $opts{config}) {
    %$self = do $opts{config};
  }
  else {
    $self = {
      debug => $opts{debug},
      max_num_np => $opts{max_num_np},
      hosts => {},
    };
  }

  my @proposed_names = keys %{$self->{max_num_np}};
  $self->{host_names} = [];

  my $logic_id = 0;
  
  for (@proposed_names) {
    eval{
      $self->{hosts}{$_} = GRID::Machine->new (
                             host        => $_,
                             debug       => $self->{debug}{$_},
                             logic_id    => $logic_id,
                           );
    };

    if ($@) {
      warn "Warning: Host $_ has not been initialized: $@";
      delete $self->{debug}{$_};
      delete $self->{max_num_np}{$_};
      delete $self->{hosts}{$_};
    }
    else {
      push @{$self->{host_names}}, $_;
      $logic_id++;
    }
  }

  bless $self, $class;
  return $self if (@{$self->{host_names}});
  return undef;
}

# Getters 

sub get_host {
  my ($self, $host_name) = @_;
  return $self->{hosts}{$host_name} if defined ($self->{hosts}{$host_name});
}

sub get_max_np {
  my $self = shift;
  return sum values %{$self->{max_num_np}};
}

sub get_num_machines {
  my $self = shift;
  my $num = @{$self->{host_names}};
  return $num;
}

sub get_machine_names {
  my $self = shift;
  return keys %{$self->{max_num_np}};
}

# Methods

sub copyandmake {
  my $self = shift;
  my %opts = @_;

  my $r = GRID::Cluster::Result->new();

  for (@{$self->{host_names}}) {
    my $machine_result = $self->{hosts}{$_}->copyandmake(%opts);
    $r->add(host_name => $_, machine_result => $machine_result);
  }

  return $r;
}

sub chdir {
  my ($self, $dir) = @_;

  my $r = GRID::Cluster::Result->new();

  for (@{$self->{host_names}}) {
    my $machine_result = $self->{hosts}{$_}->chdir($dir);
    $r->add(host_name => $_, machine_result => $machine_result);
  }

  return $r;
}

sub modput {
  my $self = shift;
  my @modules = @_;

  my $r = GRID::Cluster::Result->new();

  for (@{$self->{host_names}}) {
    my $machine_result = $self->{hosts}{$_}->modput(@modules);
    $r->add(host_name => $_, machine_result => $machine_result);
  }

  return $r;
}

sub eval {
  my $self = shift;
  my ($code, @args) = @_;

  my $r = GRID::Cluster::Result->new();

  # First round: Send eval operations to each machine
  for (@{$self->{host_names}}) {
    $self->{hosts}{$_}->send_operation("GRID::Machine::EVAL", $code, \@args);
  }

  # Second round: Receive different results from each machine 
  for (@{$self->{host_names}}) {
    my $machine_result = $self->{hosts}{$_}->_get_result();
    $r->add(host_name => $_, machine_result => $machine_result);
  }

  return $r;
}

sub qx {
  my $self = shift;
  my @commands = map { "$_ | " } @_;

  my @proc;
  my @pid;
  my %map_id_machine;
  my %id;

  my $counter = 0;
  
  my $np = @commands;
  my $lp = $np - 1;
  my $readset = IO::Select->new();

  for (@{$self->{host_names}}) {
    for my $actual_proc (0 .. $self->{max_num_np}{$_} - 1) {
      my $m = $self->get_host($_);
      ($proc[$counter], $pid[$counter]) = $m->open(shift @commands);
      $proc[$counter]->blocking(1);

      $map_id_machine{$counter} = $_;
      $readset->add($proc[$counter]);
      my $address = 0 + $proc[$counter];
      $id{$address} = $counter;

      $counter++;

      # See if all workers are busy, if so wait for one to finish
      last if (($counter > $lp) || ($counter >= $self->get_max_np()));
    }
    last if (($counter > $lp) || ($counter >= $self->get_max_np()));
  }
  
  my $count = 0;
  my @ready;
  my @result;

  do {
    push @ready, $readset->can_read unless @ready;

    my $handle = shift @ready;

    my $me = $id{0 + $handle};

    my ($aux, $bytes, $r);

    while ((!defined($bytes)) || ($bytes))  {
      $bytes = sysread($handle, $aux, BUFFERSIZE);
      $r .= $aux if ((defined($bytes)) && ($bytes));
    }

    $result[$me] = $r;

    $readset->remove($handle) if eof($handle);

    close $handle;

    if (@commands) {
      my $m = $self->get_host($map_id_machine{$me});
      ($proc[$counter], $pid[$counter]) = $m->open(shift @commands);
      $proc[$counter]->blocking(1);

      $map_id_machine{$counter} = $map_id_machine{$me};
      $readset->add($proc[$counter]);
      my $address = 0 + $proc[$counter];
      $id{$address} = $counter;

      $counter++;
    }

  } until (++$count == $np);

  my @results;
  my $i = 0;

  if (wantarray) {
    foreach (@result) {
      $results[$i] = [ split /\n/, $_ ];
      $i++;
    }
    return @results;
  }
  return \@result;
}

sub open {
  my ($self, @command) = @_;

  my @proc;
  my @pid;
  my %map_id_machine;
  my %id;

  my $counter = 0;
  my $np = @command;
  my $lp = $np - 1;
  my $readset = IO::Select->new();

  for (@{$self->{host_names}}) {
    for my $actual_proc (0 .. $self->{max_num_np}{$_} - 1) {
      my $m = $self->get_host($_);
      ($proc[$counter], $pid[$counter]) = $m->open($command[$counter]);
      $proc[$counter]->blocking(1);

      $map_id_machine{$counter} = $_;
      $readset->add($proc[$counter]);
      my $address = 0 + $proc[$counter];
      $id{$address} = $counter;

      last if (++$counter > $lp);
    }
    last if ($counter > $lp);
  }

  return GRID::Cluster::Handle->new (
    readset        => $readset,
    proc           => \@proc,  
    pid            => \@pid, 
    id             => \%id, 
    map_id_machine => \%map_id_machine
  );
}

sub open2 {
  my ($self, @command) = @_;

  my @rproc;
  my @wproc;
  my @pid;
  my %map_id_machine;
  my %id;

  my $counter = 0;
  my $np = @command;
  my $lp = $np - 1;
  my $readset = IO::Select->new();

  for (@{$self->{host_names}}) {
    for my $actual_proc (0 .. $self->{max_num_np}{$_} - 1) {
      my $m = $self->get_host($_);
      $wproc[$counter] = IO::Handle->new();
      $rproc[$counter] = IO::Handle->new();
      $pid[$counter] = $m->open2($rproc[$counter], $wproc[$counter], $command[$counter]);

      $map_id_machine{$counter} = $_;
      $readset->add($rproc[$counter]);
      my $address = 0 + $rproc[$counter];
      $id{$address} = $counter;

      last if (++$counter > $lp);
    }
    last if ($counter > $lp);
  }

  return GRID::Cluster::Handle->new (
    readset        => $readset,
    rproc          => \@rproc,
    wproc          => \@wproc,
    pid            => \@pid,
    id             => \%id,
    map_id_machine => \%map_id_machine
  );
}

sub close {
  my ($self, $cluster_handle) = @_;

  my $readset = $cluster_handle->get_readset();
  my %id = %{$cluster_handle->get_id()};
  my $np = values(%id);
  
  my $count = 0;
  my @ready;
  my @result;

  do {
    push @ready, $readset->can_read unless @ready;

    my $handle = shift @ready;

    my $me = $id{0 + $handle};

    my ($aux, $bytes, $r);

    while ((!defined($bytes)) || ($bytes))  {
      $bytes = sysread($handle, $aux, BUFFERSIZE);
      $r .= $aux if ((defined($bytes)) && ($bytes));
    }

    $result[$me] = $r;

    $readset->remove($handle) if eof($handle);

    close $handle;

  } until (++$count == $np);

  return \@result;
}

sub close2 {
  my ($self, $cluster_handle) = @_;

  my $readset = $cluster_handle->get_readset();
  my @wproc = @{$cluster_handle->get_wproc()};
  my %id = %{$cluster_handle->get_id()};
  my $np = values(%id);

  my $count = 0;
  my @ready;
  my @result;

  do {
    push @ready, $readset->can_read unless @ready;

    my $handle = shift @ready;

    my $me = $id{0 + $handle};

    my ($aux, $bytes, $r);

    while ((!defined($bytes)) || ($bytes))  {
      $bytes = sysread($handle, $aux, BUFFERSIZE);
      $r .= $aux if ((defined($bytes)) && ($bytes));
    }

    $result[$me] = $r;

    $readset->remove($handle) if eof($handle);

    $handle->close();
    $wproc[$count]->close();

  } until (++$count == $np);

  return \@result;
}

1;
__END__

=head1 NAME

GRID::Cluster - Virtual clusters using SSH links

=head1 SYNOPSIS

  use GRID::Cluster;

  my $np = 4;     # Number of processes
  my $N = 1000;   # Number of iterations
  my $clean = 0;  # The files are not removed when the execution is finished

  my $machine = [ 'host1', 'host2', 'host3' ];                # Hosts
  my $debug = { host1 => 0, host2 => 0, host3 => 0 };         # Debug mode in every host
  my $max_num_np = { host1 => 1, host2 => 1, host3 => 1 };    # Maximum number of processes supported by every host

  my $c = GRID::Cluster->new(host_names => $machine, debug => $debug, max_num_np => $max_num_np);
    || die "No machines has been initialized in the cluster";

  # Transference of files to remote hosts
  $c->copyandmake(
    dir => 'pi',
    makeargs => 'pi',
    files => [ qw{pi.c Makefile} ],
    cleanfiles => $clean,
    cleandirs => $clean, # remove the whole directory at the end
    keepdir => 1,
  );

  # This method changes the remote working directory of all hosts
  $c->chdir("pi/")  || die "Can't change to pi/\n";

  # Tasks are created and executed in remote machines using the method 'qx'
  my @commands = map {  "./pi $_ $N $np |" } 0..$np-1
  print "Pi Value: ".sum @{$c->qx(@commands)}."\n";

=head1 DESCRIPTION

This module is based on the module L<GRID::Machine>. It provides a set
of methods to create 'virtual' clusters by the use of SSH links for communications among different
remote hosts.

Since main features of C<GRID::Machine> are zero administration and minimal installation,
L<GRID::Cluster> directly inherites these features.

Mainly, C<GRID::Cluster> provides:

=over

=item *

An extension of the Perl C<qx> method. Instead of a single command it receives a 
list of commands. Commands are executed - via SSH - using the master-worker paradigm.

=item *

Services for the transference of files among machines.

=back

=head1 DEPENDENCIES

This module requires these other modules and libraries:

=over

=item * C<GRID::Machine> module by Casiano Rodriguez Leon

=back

=head1 METHODS

=head2 The Constructor C<new>

This method returns a new instance of an object.

There are two ways to call the constructor. The first one looks like:

  my $cluster = GRID::Cluster->new(
                                   debug      => {machine1 => 0, machine2 => 0,...},
                                   max_num_np => {machine1 => 1, machine2 => 1,...},
                                  );

where:

=over 2

=item *

C<debug> is a reference to a hash that specifies which machines will be in debugging mode.
It is optional.

=item *

C<max_num_np> is a reference to a hash containing the maximum number of processes supported for each machine.

=back

The second one looks like:

  my $cluster = GRID::Cluster->new(config => $config_file_name);

where:

=over 2

=item *

C<config> is the name of the file containing the cluster specification.
The specification is written in Perl itself.
The code inside the C<config> file must return a list defining
the C<max_num_np> and C<debug> parameters as in the previous
call. See the following example:

  $ cat -n MachineConfig.pm
  1  my %debug = (machine1 => 0, machine2 => 0, machine3 => 0, machine4 => 0);
  2  my %max_num_np = (machine1 => 3, machine2 => 1, machine3 => 1, machine4 => 1);
  3
  4  return (debug => \%debug, max_num_np => \%max_num_np);

=back

=head2 The Method C<modput>

The syntax of the method C<modput> is:

  my $result = $cluster->modput(@modules);

It receives a list of strings describing modules (like 'Math::Prime::XS'), and it
returns a L<GRID::Cluster::Result> object.

An example is in following lines:

  $ cat -n modput.pl
  1  #!/usr/bin/perl
  2  use warnings;
  3  use strict;
  4
  5  use GRID::Cluster;
  6  use Data::Dumper;
  7
  8  my $cluster = GRID::Cluster->new( debug =>      { orion => 0, beowulf => 0 },
  9                                    max_num_np => { orion => 1, beowulf => 1 } );
 10
 11
 12  my $result = $cluster->modput('Math::Prime::XS');
 13
 14  $result = $cluster->eval(q{
 15                use Math::Prime::XS qw(primes);
 16
 17                primes(9);
 18              }
 19            );
 20
 21  print Dumper($result);

When this program is executed, the following output is produced:

  $ ./modput.pl
  $VAR1 = bless( {
                   'beowulf' => bless( {
                                         'stderr' => '',
                                         'errmsg' => '',
                                         'type' => 'RETURNED',
                                         'stdout' => '',
                                         'errcode' => 0,
                                         'results' => [
                                                        2,
                                                        3,
                                                        5,
                                                        7
                                                      ]
                                       }, 'GRID::Machine::Result' ),
                   'orion' => bless( {
                                       'stderr' => '',
                                       'errmsg' => '',
                                       'type' => 'RETURNED',
                                       'stdout' => '',
                                       'errcode' => 0,
                                       'results' => [
                                                      2,
                                                      3,
                                                      5,
                                                      7
                                                    ]
                                     }, 'GRID::Machine::Result' )
                 }, 'GRID::Cluster::Result' );

=head2 The Method C<eval>

The syntax of the method C<eval> is:

  $result = $cluster->eval($code, @args)

This method evaluates $code in the cluster, passing arguments and returning a
L<GRID::Cluster::Result> object.

An example of use:

   $ cat -n eval_pi.pl
   1  #!/usr/bin/perl
   2  use warnings;
   3  use strict;
   4
   5  use GRID::Cluster;
   6  use Data::Dumper;
   7
   8  my $cluster = GRID::Cluster->new( debug =>      { orion => 0, beowulf => 0, localhost => 0, bw => 0 },
   9                                    max_num_np => { orion => 1, beowulf => 1, localhost => 1, bw => 1} );
  10
  11  my @machines = ('orion', 'bw', 'beowulf', 'localhost');
  12  my $np = @machines;
  13  my $N = 1000000;
  14
  15  my $r = $cluster->eval(q{
  16
  17               my ($N, $np) = @_;
  18
  19               my $sum = 0;
  20
  21               for (my $i = SERVER->logic_id; $i < $N; $i += $np) {
  22                   my $x = ($i + 0.5) / $N;
  23                   $sum += 4 / (1 + $x * $x);
  24               }
  25
  26               $sum /= $N;
  27
  28           }, $N, $np );
  29
  30  print Dumper($r);
  31
  32  my $result = 0;
  33
  34  foreach (@machines) {
  35    $result += $r->{$_}{results}[0];
  36  }
  37
  38  print "\nEl resultado del cálculo de PI es: $result\n";

The cluster initialization (lines 8 -- 9) assigns a logical identifier to each machine.
In lines 15 -- 28, the C<eval> method evaluates the block of code located at the C<q>
operator for each machine of the cluster. In lines 32 - 36, an addition of every
obtained values is performed. So on, the example produces the following output:

  $VAR1 = bless( {
                   'bw' => bless( {
                                    'stderr' => '',
                                    'errmsg' => '',
                                    'type' => 'RETURNED',
                                    'stdout' => '',
                                    'errcode' => 0,
                                    'results' => [
                                                   '0.785398913397203'
                                                 ]
                                  }, 'GRID::Machine::Result' ),
                   'beowulf' => bless( {
                                         'stderr' => '',
                                         'errmsg' => '',
                                         'type' => 'RETURNED',
                                         'stdout' => '',
                                         'errcode' => 0,
                                         'results' => [
                                                        '0.785398413397751'
                                                      ]
                                       }, 'GRID::Machine::Result' ),
                   'orion' => bless( {
                                       'stderr' => '',
                                       'errmsg' => '',
                                       'type' => 'RETURNED',
                                       'stdout' => '',
                                       'errcode' => 0,
                                       'results' => [
                                                      '0.785397913397739'
                                                    ]
                                     }, 'GRID::Machine::Result' ),
                   'localhost' => bless( {
                                           'stderr' => '',
                                           'errmsg' => '',
                                           'type' => 'RETURNED',
                                           'stdout' => '',
                                           'errcode' => 0,
                                           'results' => [
                                                          '0.785397413397209'
                                                        ]
                                         }, 'GRID::Machine::Result' )
                 }, 'GRID::Cluster::Result' );

  El resultado del cálculo de PI es: 3.1415926535899

The L<GRID::Cluster::Result> object contains the obtained results, and the addition of every
results is the final calculation of number PI.

=head2 The Method C<qx>

The syntax of the method C<qx> is:

  my $result = $cluster->qx(@commands); 

It receives a list of commands and executes each command as a remote process.
It uses a farm-based approach. At some time a chunk of commands - the size
of the chunk depending on the number of processors - is being executed. 
As soon as some command finishes, another one is sent to the new idle worker (if there
are pending tasks).

In a scalar context, a reference to a list that contains every results is returned.
Such list contains the outputs of the C<@commands>. Observe however that no 
assumption can be made about the processor where an individual command C<c> in C<@commands>
is eexecuted. See the following example:

An example of use:

  $ cat -n uname_echo_qx.pl
     1	  #!/usr/bin/perl
     2	  use strict;
     3	  use warnings;
     4	
     5	  use GRID::Cluster;
     6	  use Data::Dumper;
     7	
     8	  my $cluster = GRID::Cluster->new(max_num_np => {orion => 1, europa => 1},);
     9	
    10	  my @commands = ("uname -a", "echo Hello");
    11	  my $result = $cluster->qx(@commands);
    12	
    13	  print Dumper($result);


The result of this example produces the following output:

  $ ./uname_echo_qx.pl 
  $VAR1 = [                                                   
            'Linux europa 2.6.24-24-generic #1 SMP Wed Apr 15 15:11:35 UTC 2009 x86_64 GNU/Linux
  ',                                                                                            
            'Hello                                                                              
  '                                                                                             
          ];  

Observe that the first output corresponds to the first command C<uname -a>, and the second 
output to the second command C<echo Hello>. Notice also that we can't assume that the first command 
will be executed in the first machine, the second one in the second machine, etc. We can only
be certain that all the commands will be executed in some machine of the cluster pool.

=head2 The Method C<copyandmake>

The syntax of the method C<copyandmake> is:

  my $result = $cluster->copyandmake(
                 dir => $dir,
                 files => [ @files ],      # files to transfer
                 make => $command,         # execute $command $commandargs
                 makeargs => $commandargs, # after the transference
                 cleanfiles => $cleanup,   # remove files at the end
                 cleandirs => $cleanup,    # remove the whole directory at the end
               )

and it returns a L<GRID::Cluster::Result> object.

C<copyandmake> copies (using C<scp>) the files
C<@files> to a directory named C<$dir> in remote machines.
The directory C<$dir> will be created if it does not exists. After the file transfer
the C<command> specified by the C<copyandmake> option

                     make => 'command'

will be executed with the arguments specified in the option C<makeargs>.
If the C<make> option is not specified but there is a file named C<Makefile>
between the transferred files, the C<make> program will be executed.
Set the C<make> option to number 0 or the string C<''> if you want to
avoid the execution of any command after the transfer.
The transferred files will be removed when the connection finishes if the
option C<cleanfiles> is set. If the option C<cleandirs> is set,
the
created directory and all the files below it will be removed.
Observe that the directory and the files
will be kept if they were not created by this connection.
The call to C<copyandmake> by default sets C<dir> as the current directory in
remote machines. Use the option C<keepdir =E<gt> 1> to one to avoid this.

=head2 The Method C<chdir>

The syntax of this method is as follows:

  my $result = $cluster->chdir($remote_dir);

and it returns a L<GRID::Cluster::Result> object.

The method C<chdir> changes the remote working directory to $remote_dir in every
remote machine.

=head1 INSTALLATION

To install C<GRID::Cluster>, follow these steps:

=over 2

=item  * 

Set automatic ssh-authentication with machines where you have an account.

SSH includes the ability to authenticate users using public keys. Instead of
authenticating the user with a password, the SSH server on the remote machine will
verify a challenge signed by the user's I<private key> against its copy
of the user's I<public key>. To achieve this automatic ssh-authentication
you have to:

=over 2

=item * 

Generate a public key use the C<ssh-keygen> utility. For example:

  local.machine$ ssh-keygen -t rsa -N ''

The option C<-t> selects the type of key you want to generate.
There are three types of keys: I<rsa1>, I<rsa> and I<dsa>.
The C<-N> option is followed by the I<passphrase>. The C<-N ''> setting
indicates that no pasphrase will be used. This is useful when used
with key restrictions or when dealing with cron jobs, batch
commands and automatic processing which is the context in which this
module was designed.
If still you don't like to have a private key without passphrase,
provide a passphrase and use C<ssh-agent>
to avoid the inconvenience of typing the passphrase each time.
C<ssh-agent> is a program you run once per login sesion and load your keys into.
From that moment on, any C<ssh> client will contact C<ssh-agent>
and no more passphrase typing will be needed.

By default, your identification will be saved in a file C</home/user/.ssh/id_rsa>.
Your public key will be saved in C</home/user/.ssh/id_rsa.pub>.

=item * 

Once you have generated a key pair, you must install the public key on the
remote machine. To do it, append the public component of the key in

  /home/user/.ssh/id_rsa.pub

to file

  /home/user/.ssh/authorized_keys

on the remote machine.
If the C<ssh-copy-id> script is available, you can do it using:

  local.machine$ ssh-copy-id -i ~/.ssh/id_rsa.pub user@remote.machine

Alternatively you can write the following command:

  $ ssh remote.machine "umask 077; cat >> .ssh/authorized_keys" < /home/user/.ssh/id_rsa.pub

The C<umask> command is needed since the SSH server will refuse to
read a C</home/user/.ssh/authorized_keys> files which have loose permissions.

=item * 

Edit your local configuration file C</home/user/.ssh/config> (see C<man ssh_config>
in UNIX) and create a new section for C<GRID::Cluster> connections to that host.
Here follows an example:

...

  # A new section inside the config file:
  # it will be used when writing a command like:
  #                  $ ssh gridyum
 
  Host gridyum
 
  # My username in the remote machine
  user my_login_in_the_remote_machine
 
  # The actual name of the machine: by default the one provided in the
  # command line
  Hostname real.machine.name

  # The port to use: by default 22
  Port 2048

  # The identitiy pair to use. By default ~/.ssh/id_rsa and ~/.ssh/id_dsa
  IdentityFile /home/user/.ssh/yumid

  # Useful to detect a broken network
  BatchMode yes

  # Useful when the home directory is shared across machines,
  # to avoid warnings about changed host keys when connecting
  # to local host
  NoHostAuthenticationForLocalhost yes


  # Another section ...
  Host another.remote.machine an.alias.for.this.machine
  user mylogin_there

  ...

  This way you don't have to specify your I<login> name on the remote machine even if it
  differs from your  I<login> name in the local machine, you don't have to specify the
  I<port> if it isn't 22, etc. This is the I<recommended> way to work with C<GRID::Cluster>.
  Avoid cluttering the constructor C<new>.

=item * 

Once the public key is installed on the remote machine you should be able to
authenticate using your private key

  $ ssh remote.machine
  Linux remote.machine 2.6.15-1-686-smp #2 SMP Mon Mar 6 15:34:50 UTC 2006 i686
  Last login: Sat Jul  7 13:34:00 2007 from local.machine
  user@remote.machine:~$

You can also automatically execute commands in the remote server:

  local.machine$ ssh remote.machine uname -a
  Linux remote.machine 2.6.15-1-686-smp #2 SMP Mon Mar 6 15:34:50 UTC 2006 i686 GNU/Linux

=back

=item  *

Before running the tests. Set on the local machine the environment variable
C<GRID_REMOTE_MACHINES> to point to a set of machines that is available using automatic authentication.
For example, on a C<bash>:

        export GRID_REMOTE_MACHINES=user@machine_1.domain:user@machine_2.domain:...:user@machine_n.domain

Otherwise most connectivity tests will be skipped. This and the previous steps are optional.

=item *

Follow the traditional steps:

   perl Makefile.PL
   make
   make test
   make install

=back

=head1 SEE ALSO

=over 2

=item * L<GRID::Cluster>

=item * L<GRID::Machine>

=item * L<IPC::PerlSSH>

=item * L<http://www.openssh.com>

=item * L<http://www.csm.ornl.gov/torc/C3/>

=item * Man pages of C<ssh>, C<ssh-key-gen>, C<ssh_config>, C<scp>,
C<ssh-agent>, C<ssh-add>, C<sshd>

=back

=head1 AUTHORS

Eduardo Segredo Gonzalez E<lt>esegredo@ull.esE<gt> and
Casiano Rodriguez Leon E<lt>casiano@ull.esE<gt>

=head1 AKNOWLEDGEMENTS

This work has been supported by the EC (FEDER) and
the Spanish Ministry of Science and Innovation inside the 'Plan
Nacional de I+D+i' with the contract number TIN2008-06491-C04-02.

Also, it has been supported by the Canary Government project number
PI2007/015.

The work of Eduardo Segredo has been developed under the contract
PTA2003-02-01053.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2009 by Casiano Rodriguez Leon and Eduardo Segredo Gonzalez.
All rights reserved.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

=cut
