package Mojo::Run3;
use Mojo::Base 'Mojo::EventEmitter';

use Errno qw(EAGAIN ECONNRESET EINTR EPIPE EWOULDBLOCK EIO);
use IO::Handle;
use Mojo::IOLoop::ReadWriteFork::SIGCHLD;
use Mojo::IOLoop;
use Mojo::Promise;

our $VERSION = '0.01';

our @SAFE_SIG = grep {
  !m!^(NUM\d+|__[A-Z0-9]+__|ALL|CATCHALL|DEFER|HOLD|IGNORE|MAX|PAUSE|RTMAX|RTMIN|SEGV|SETS)$!
} keys %SIG;

has ioloop => sub { Mojo::IOLoop->singleton }, weak => 1;

sub close {
  my ($self, $name) = @_;
  my $reactor = $self->ioloop->reactor;
  my $h       = delete $self->{fh}{$name} or return $self;
  $reactor->remove($h) unless $name eq 'stdin';
  $h->close;

  return $self;
}

sub exit_status { shift->status >> 8 }

sub kill {
  my ($self, $signal) = (@_, 15);
  return $self->{pid} ? kill $signal, $self->{pid} : -1;
}

sub run_p {
  my ($self, $cb) = @_;
  my $p = Mojo::Promise->new;
  $self->once(finish => sub { $p->resolve($_[0]) });
  $self->start($cb);
  return $p;
}

sub pid    { shift->{pid}    // 0 }
sub status { shift->{status} // -1 }

sub start {
  my ($self, $cb) = @_;

  $self->ioloop->next_tick(sub {
    $! = 0;
    return $self->_err("Can't pipe: $@", $!) unless my $fh = eval { $self->_prepare_filehandles };
    return $self->_err("Can't fork: $!", $!) unless defined($self->{pid} = fork);
    return $self->{pid} ? $self->_start_parent($fh) : $self->_start_child($fh, $cb);
  });

  return $self;
}

sub write {
  my ($self, $chunk, $cb) = @_;
  $self->once(drain => $cb) if $cb;
  $self->{buffer}{stdin} .= $chunk;
  $self->_write if $self->{fh}{stdin};
  return $self;
}

sub _cleanup {
  my ($self) = @_;

  my $reactor = $self->ioloop->reactor;
  for my $name (qw(stdin stderr stdout)) {
    my $h = delete $self->{fh}{$name} or next;
    $reactor->remove($h) unless $name eq 'stdin';
    $h->close;
  }
}

sub _err {
  my ($self, $err, $errno) = @_;
  $self->{status} = $errno;
  $self->emit(error => $err)->emit('finish');
  $self->_cleanup;
}

sub _make_pipe {
  my ($self) = @_;
  pipe my $read, my $write or die $!;
  $write->autoflush(1);
  return $read, $write;
}

sub _maybe_terminate {
  my ($self, $pending_event) = @_;
  $self->{$pending_event} = 0;
  return if $self->{wait_eof} or $self->{wait_sigchld};

  $self->_cleanup;
  for my $cb (@{$self->subscribers('finish')}) {
    $self->emit(error => $@) unless eval { $self->$cb; 1 };
  }
}

sub _prepare_filehandles {
  my ($self) = @_;

  my %fh;
  @fh{qw(stdin_read stdin_write)}   = $self->_make_pipe;
  @fh{qw(stdout_read stdout_write)} = $self->_make_pipe;
  @fh{qw(stderr_read stderr_write)} = $self->_make_pipe;

  return \%fh;
}

sub _read {
  my ($self, $name, $handle) = @_;

  my $read = $handle->sysread(my $buf, 131072, 0);
  unless (defined $read) {
    return if $! == EAGAIN || $! == EINTR || $! == EWOULDBLOCK;    # Retry
    return if $! == ECONNRESET || $! == EIO;
    return $self->emit(error => $!);
  }

  return $read ? $self->emit(read => $buf, $name) : $self->_maybe_terminate('wait_eof');
}

sub _start_child {
  my ($self, $fh, $code) = @_;

  delete($fh->{$_})->close for (qw(stdin_write stdout_read stderr_read));
  $fh = {stdin => $fh->{stdin_read}, stdout => $fh->{stdout_write}, stderr => $fh->{stderr_write}};

  open STDIN,  '<&' . fileno($fh->{stdin})  or die "Could not dup stdin: $!";
  open STDOUT, '>&' . fileno($fh->{stdout}) or die "Could not dup stdout: $!";
  open STDERR, '>&' . fileno($fh->{stderr}) or die "Could not dup stderr: $!";
  STDOUT->autoflush(1);
  STDERR->autoflush(1);

  @SIG{@SAFE_SIG} = ('DEFAULT') x @SAFE_SIG;
  ($@, $!) = ('', 0);

  $self->{pid} = $$;
  eval { $self->$code };
  my ($err, $errno) = ($@, $@ ? 255 : $! || 0);
  print STDERR $@ if length $@;
  POSIX::_exit($errno) || exit $errno;
}

sub _start_parent {
  my ($self, $fh) = @_;

  delete($fh->{$_})->close for (qw(stdin_read stdout_write stderr_write));
  $fh = {stdin => $fh->{stdin_write}, stdout => $fh->{stdout_read}, stderr => $fh->{stderr_read}};

  weaken $self;
  my $reactor = $self->ioloop->reactor;
  for my $name (qw(stderr stdout)) {
    my $h = $fh->{$name};
    $reactor->io($h, sub { $self ? $self->_read($name => $h) : $_[0]->remove($h) })
      ->watch($h, 1, 0);
  }

  @$self{qw(wait_eof wait_sigchld)} = (1, 1);
  Mojo::IOLoop::ReadWriteFork::SIGCHLD->singleton->waitpid(
    $self->{pid} => sub {
      $self->{status} = $_[0];
      $self->_maybe_terminate('wait_sigchld');
    }
  );

  $self->{fh} = $fh;
  $self->emit('spawn');
  $self->_write;
}

sub _write {
  my $self = shift;
  return unless length $self->{buffer}{stdin};

  my $stdin_write = $self->{fh}{stdin};
  my $written     = $stdin_write->syswrite($self->{buffer}{stdin});
  unless (defined $written) {
    return if $! == EAGAIN || $! == EINTR || $! == EWOULDBLOCK;
    return $self->kill(9) if $! == ECONNRESET || $! == EPIPE;
    return $self->emit(error => $!);
  }

  substr $self->{buffer}{stdin}, 0, $written, '';
  return $self->emit('drain') unless length $self->{buffer}{stdin};
  return $self->ioloop->next_tick(sub { $self->_write });
}

1;

=encoding utf8

=head1 NAME

Mojo::Run3 - Run a subprocess and read/write to it

=head1 SYNOPSIS

  my $run3 = Mojo::Run3->new;
  $run3->on(read => sub ($run3, $bytes, $conduit) {
    print STDOUT $bytes if $conduit eq 'stdout';
  });

  $run3->run_p(sub { exec qw(/usr/bin/ls -l /tmp) })->wait;

=head1 DESCRIPTION

L<Mojo::Run3> allows you to fork a subprocess which you can L</write> STDIN to,
and L</read> STDERR and STDOUT, without blocking the the event loop.

This module is currently EXPERIMENTAL, but unlikely to change much.

=head1 EVENTS

=head2 drain

  $run3->on(drain => sub ($run3) { });

Emitted after L</write> has written the whole buffer to the subprocess.

=head2 error

  $run3->on(error => sub ($run3, $str) { });

Emitted when something goes wrong.

=head2 finish

  $run3->on(finish => sub ($run3) { });

Emitted when the subprocess has ended. L</error> might be emitted before
L</finish>, but L</finish> will always be emitted at some point after L</start>
as long as the subprocess actually stops. L</status> will contain C<$!> if the
subprocess could not be started or the exit code from the subprocess.

=head2 read

  $run3->on(finish => sub ($run3, $bytes, $conduit) { });

Emitted when the subprocess write bytes. C<$conduit> can be "stdout" or
"stderr".

=head2 spawn

  $run3->on(spawn => sub ($run3) { });

Emitted in the parent process after the subprocess has been forked.

=head1 ATTRIBUTES

=head2 ioloop

  $ioloop = $run3->ioloop;
  $run3   = $run3->ioloop(Mojo::IOLoop->singleton);

Holds a L<Mojo::IOLoop> object.

=head1 METHODS

=head2 close

  $run3 = $run3->close('stdin');

Can be used to close C<STDIN>. This is useful after piping data into a process
like C<cat>.

=head2 exit_status

  $int = $run3->exit_status;

Returns the exit status part of L</status>, which will should be a number from
0 to 255.

=head2 kill

  $int = $run3->kill($signal);

Used to send a C<$signal> to the subprocess. Returns C<-1> if no process
exists, C<0> if the process could not be signalled and C<1> if the signal was
successfully sent.

=head2 pid

  $int = $run3->pid;

Process ID of the subprocess after L</start> has successfully started.

=head2 run_p

  $p = $run3->run_p(sub ($run3) { ... })->then(sub ($run3) { ... });

Will L</start> the subprocess and the promise will be fulfilled when L</finish>
is emitted.

=head2 start

  $run3 = $run3->start(sub ($run3, @) { ... });

Will start the subprocess. The code block passed in will be run in the child
process. The code below can be used if you want to run another program:

  $run3 = $run3->start(sub { exec @my_other_program_with_args });
  $run3 = $run3->start(sub { exec qw(/usr/bin/ls -l /tmp) });

=head2 status

  $int = $run3->status;

Holds the exit status of the program or C<$!> if the program failed to start.
The value includes signals and coredump flags, but L</exit_status> can be used
be used to get the value from 0 to 255.

=head2 write

  $run3 = $run3->write($bytes);
  $run3 = $run3->write($bytes, sub ($run3) { ... });

Used to write C<$bytes> to the subprocess. The optional callback will be called
on the next L</drain> event.

=head1 AUTHOR

Jan Henning Thorsen

=head1 COPYRIGHT AND LICENSE

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Mojo::IOLoop::ReadWriteFork>, L<IPC::Run3>.

=cut
