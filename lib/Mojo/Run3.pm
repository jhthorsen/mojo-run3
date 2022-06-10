package Mojo::Run3;
use Mojo::Base 'Mojo::EventEmitter';

use Carp qw(croak);
use IO::Handle;
use IO::Pty;
use Mojo::IOLoop;
use Mojo::Promise;
use Scalar::Util qw(blessed weaken);

our $VERSION = '0.01';

has ioloop => sub { Mojo::IOLoop->singleton }, weak => 1;
has pid    => 0;
has status => 0;

sub close { }
sub kill  { }
sub start { }
sub write { }

1;

=encoding utf8

=head1 NAME

Mojo::Run3 - Run a subprocess and read/write to it

=head1 SYNOPSIS

TODO

=head1 DESCRIPTION

L<Mojo::Run3> allows you to fork a subprocess which you can L</write> STDIN to,
and L</read> STDERR and STDOUT, without blocking the the event loop.

=head1 ATTRIBUTES

=head2 ioloop

  $ioloop = $run->ioloop;
  $run    = $run->ioloop(Mojo::IOLoop->singleton);

=head2 pid

  $int = $run->pid;

=head2 status

  $int = $run->status;

=head1 METHODS

=head2 close

  $run = $run->close('stdin');

=head2 kill

  $int = $run->kill($signal);

=head2 start

  $run = $run->kill(sub ($run, $fh) { ... });

=head2 write

  $run = $run->write($bytes);
  $run = $run->write($bytes, sub ($run) { ... });

=head1 AUTHOR

Jan Henning Thorsen

=head1 COPYRIGHT AND LICENSE

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Mojo::IOLoop::ReadWriteFork>, L<IPC::Run3>.

=cut
