package Mojo::Run3;
use Mojo::Base 'Mojo::EventEmitter';

use Carp  qw(croak);
use Errno qw(EAGAIN ECONNRESET EINTR EPIPE EWOULDBLOCK EIO);
use IO::Handle;
use IO::Pty;
use Mojo::IOLoop::ReadWriteFork::SIGCHLD;
use Mojo::IOLoop;
use Mojo::Util qw(term_escape);
use Mojo::Promise;
use POSIX        qw(sysconf _SC_OPEN_MAX);
use Scalar::Util qw(blessed weaken);

use constant DEBUG        => $ENV{MOJO_RUN3_DEBUG} && 1;
use constant MAX_OPEN_FDS => sysconf(_SC_OPEN_MAX);

our $VERSION = '1.03';

our @SAFE_SIG
  = grep { !m!^(NUM\d+|__[A-Z0-9]+__|ALL|CATCHALL|DEFER|HOLD|IGNORE|MAX|PAUSE|RTMAX|RTMIN|SEGV|SETS)$! } keys %SIG;

has driver => sub { +{stdin => 'pipe', stdout => 'pipe', stderr => 'pipe'} };
has ioloop => sub { Mojo::IOLoop->singleton }, weak => 1;

sub bytes_waiting {
  my ($self, $name) = (@_, 'stdin');
  return length($self->{buffer}{$name} // '');
}

sub close {
  my ($self, $conduit) = @_;
  return $self->_close_other if $conduit eq 'other';
  return $self->_close_slave if $conduit eq 'slave';

  my $fh = $self->{fh};
  return $self unless my $handle = $fh->{$conduit};

  $self->_d('close %s (%s)', $conduit, $fh->{$conduit} // 'undef') if DEBUG;
  $self->_remove($handle, 1);
  $handle->close;
  return $self;
}

sub exit_status { shift->status >> 8 }
sub handle      { $_[0]->{fh}{$_[1]} }

sub kill {
  my ($self, $signal) = (@_, 15);
  $self->_d('kill %s %s', $signal, $self->{pid} // 0) if DEBUG;
  return $self->{pid} ? kill $signal, $self->{pid} : -1;
}

sub run_p {
  my ($self, $cb) = @_;
  my $p = Mojo::Promise->new;
  $self->once(finish => sub { $p->resolve($_[0]) });
  $self->start($cb);
  return $p;
}

sub pid    { shift->{pid}    // -1 }
sub status { shift->{status} // -1 }

sub start {
  my ($self, $cb) = @_;
  $self->ioloop->next_tick(sub { $self and $self->_start($cb) });
  return $self;
}

sub write {
  my $cb = ref $_[-1] eq 'CODE' && pop;
  my ($self, $chunk, $conduit) = (@_, 'stdin');
  $self->once(drain => $cb) if $cb;
  $self->{buffer}{$conduit} .= $chunk;
  $self->_write($conduit);
  return $self;
}

sub _cleanup {
  my ($self, $signal) = @_;
  return unless $self->{pid};
  $self->close($_) for qw(slave pty stdin stderr stdout);
  $self->kill($signal) if $signal;
}

sub _close_from_child {
  my ($self, $conduit) = @_;
  delete $self->{watching}{$conduit};    # $conduit can also be "pid"
  $self->_d('closed=%s watching="%s"', $conduit, join ' ', sort keys %{$self->{watching}}) if DEBUG;
  return 0                                                                                 if keys %{$self->{watching}};

  $self->close($_) for keys %{$self->{fh}};
  for my $cb (@{$self->subscribers('finish')}) {
    $self->emit(error => $@) unless eval { $self->$cb; 1 };
  }

  return 1;
}

sub _close_other {
  my ($self) = @_;
  croak "Cannot close 'other' in parent process!" if $self->pid != 0;

  my $fh = delete $self->{fh};
  $fh->{$_}->close for keys %$fh;

  local $!;
  for my $fileno (0 .. MAX_OPEN_FDS - 1) {
    next if fileno(STDIN) == $fileno;
    next if fileno(STDOUT) == $fileno;
    next if fileno(STDERR) == $fileno;
    POSIX::close($fileno);
  }

  return $self;
}

sub _close_slave {
  my ($self) = @_;
  my $pty = $self->{fh}{pty};
  $self->_d('close slave (%s)', $pty && ${*$pty}{io_pty_slave} || 'undef') if DEBUG;
  $pty->close_slave                                                        if $pty;
  return $self;
}

sub _d {
  my ($self, $format, @val) = @_;
  local $!;    # Do not reset $! in ex _read()
  warn sprintf "[run3:%s] $format\n", $self->{pid} // 0, @val;
}

sub _fail {
  my ($self, $err, $errno) = @_;
  $self->_d('finish %s (%s)', $err, $errno) if DEBUG;
  $self->{status} = $errno;
  $self->emit(error => $err)->emit('finish');
  $self->_cleanup;
}

sub _read {
  my ($self, $name, $handle) = @_;

  my $n_bytes = $handle->sysread(my $buf, 131072, 0);
  if ($n_bytes) {
    $self->_d('%s >>> %s (%i)', $name, term_escape($buf) =~ s!\n!\\n!gr, $n_bytes) if DEBUG;
    return $self->emit($name => $buf);
  }
  elsif (defined $n_bytes) {
    return $self->_remove($handle, 0)->_close_from_child($name);    # EOF
  }
  else {
    $self->_d('op=read conduit=%s errstr="%s" errno=%s', $name, $!, int $!) if DEBUG;
    return undef       if $! == EAGAIN     || $! == EINTR || $! == EWOULDBLOCK;    # Retry
    return $self->kill if $! == ECONNRESET || $! == EPIPE;                         # Error
    return $self->_remove($handle, 0)->_close_from_child($name) if $! == EIO;      # EOF on PTY raises EIO
    return $self->emit(error => $!);
  }
}

sub _redirect {
  my ($self, $conduit, $real, $virtual) = @_;
  return $real->close || die "Couldn't close $conduit: $!" unless $virtual;
  $real->autoflush(1);
  return open($real, ($conduit eq 'stdin' ? '<&=' : '>&='), fileno($virtual)) || die "Couldn't dup $conduit: $!";
}

sub _remove {
  my ($self, $handle, $delete) = @_;
  my $fh      = $self->{fh};
  my $reactor = $self->ioloop->reactor;

  for my $name (keys %$fh) {
    next unless $fh->{$name} and $fh->{$name} eq $handle;
    $reactor->remove($fh->{$name});
    delete $fh->{$name} if $delete;
    delete $self->{watching}{$name};
  }

  return $self;
}

sub _start {
  my ($self, $cb) = @_;

  my $options = $self->driver;
  $options        = {stdin => $options, stdout => 'pipe', stderr => 'pipe'} unless ref $options;
  $options->{pty} = 'pty' if $options->{pty};
  map { $options->{$_} //= 'pipe' } qw(stdin stdout stderr) if $options->{pipe};

  # Prepare IPC filehandles
  my ($pty, %child, %parent);
  for my $conduit (qw(pty stdin stdout stderr)) {
    my $driver = $options->{$conduit} // 'close';
    if ($driver eq 'pty') {
      $pty ||= IO::Pty->new;
      ($child{$conduit}, $parent{$conduit}) = ($pty->slave, $pty);
    }
    elsif ($driver eq 'pipe') {
      pipe my $read, my $write or return $self->_fail("Can't create pipe: $!", $!);
      ($child{$conduit}, $parent{$conduit}) = $conduit eq 'stdin' ? ($read, $write) : ($write, $read);
    }

    $self->_d('conduit=%s child=%s parent=%s', $conduit, $child{$conduit} // '', $parent{$conduit} // '') if DEBUG;
  }

  # Child
  unless ($self->{pid} = fork) {
    return $self->_fail("Can't fork: $!", $!) unless defined $self->{pid};
    $self->{fh} = \%child;
    $pty->make_slave_controlling_terminal if $pty and ($options->{make_slave_controlling_terminal} // 1);
    $_->close for values %parent;

    $self->_redirect(stdin  => \*STDIN,  $child{stdin});
    $self->_redirect(stdout => \*STDOUT, $child{stdout});
    $self->_redirect(stderr => \*STDERR, $child{stderr});

    @SIG{@SAFE_SIG} = ('DEFAULT') x @SAFE_SIG;
    ($@, $!) = ('', 0);

    eval { $self->$cb };
    my ($err, $errno) = ($@, $@ ? 255 : $! || 0);
    print STDERR $err if length $err;
    POSIX::_exit($errno) || exit $errno;
  }

  # Parent
  $self->{fh} = \%parent;
  $self->{fh}{pty} = $pty if $pty;

  # Close child filehandles unless we want to keep the tty open for a bit
  for my $fh (values %child) {
    if (blessed $fh and $fh->can('set_raw')) {
      $self->close('slave') if $options->{close_slave} // 1;
    }
    else {
      $fh->close;
    }
  }

  weaken $self;
  my $reactor = $self->ioloop->reactor;
  my %uniq;
  for my $conduit (qw(pty stdout stderr)) {
    next unless my $fh = $parent{$conduit};
    next if $uniq{$fh}++;
    $reactor->io($fh, sub { $self ? $self->_read($conduit => $fh) : $_[0]->remove($fh) });
    $reactor->watch($fh, 1, 0);
    $self->{watching}{$conduit} = 1;
  }

  $self->_d('waitpid %s', $self->{pid}) if DEBUG;
  $self->{watching}{pid} = 1;
  Mojo::IOLoop::ReadWriteFork::SIGCHLD->singleton->waitpid(
    $self->{pid} => sub {
      return unless $self;
      $self->{status} = $_[0];
      $self->_close_from_child('pid');
    }
  );

  $self->emit('spawn');
  $self->_write($_) for qw(pty stdin);
}

sub _write {
  my ($self, $conduit) = @_;
  return unless length $self->{buffer}{$conduit};
  return unless my $fh = $self->{fh}{$conduit};

  my $n_bytes = $fh->syswrite($self->{buffer}{$conduit});
  if (defined $n_bytes) {
    my $buf = substr $self->{buffer}{$conduit}, 0, $n_bytes, '';
    $self->_d('%s <<< %s (%i)', $conduit, term_escape($buf) =~ s!\n!\\n!gr, length $buf) if DEBUG;
    return $self->emit('drain') unless length $self->{buffer}{$conduit};
    return $self->ioloop->next_tick(sub { $self->_write });
  }
  else {
    $self->_d('op=write conduit=%s errstr="%s" errno=%s', $conduit, $!, $!) if DEBUG;
    return                if $! == EAGAIN     || $! == EINTR || $! == EWOULDBLOCK;
    return $self->kill(9) if $! == ECONNRESET || $! == EPIPE;
    return $self->emit(error => $!);
  }
}

sub DESTROY { shift->_cleanup(9) unless ${^GLOBAL_PHASE} eq 'DESTRUCT' }

1;

=encoding utf8

=head1 NAME

Mojo::Run3 - Run a subprocess and read/write to it

=head1 SYNOPSIS

  use Mojo::Base -strict, -signatures;
  use Mojo::Run3;

This example gets "stdout" events when the "ls" command emits output:

  use IO::Handle;
  my $run3 = Mojo::Run3->new;
  $run3->on(stdout => sub ($run3, $bytes) {
    STDOUT->syswrite($bytes);
  });

  $run3->run_p(sub { exec qw(/usr/bin/ls -l /tmp) })->wait;

This example does the same, but on a remote host using ssh:

  my $run3 = Mojo::Run3->new->driver({pty => 1, pipe => 1}});

  $run3->once(pty => sub ($run3, $bytes) {
    $run3->write("my-secret-password\n", "pty") if $bytes =~ /password:/;
  });

  $run3->on(stdout => sub ($run3, $bytes) {
    STDOUT->syswrite($bytes);
  });

  $run3->run_p(sub { exec qw(ssh example.com ls -l /tmp) })->wait;

=head1 DESCRIPTION

L<Mojo::Run3> allows you to fork a subprocess which you can write STDIN to, and
read STDERR and STDOUT without blocking the the event loop.

This module also supports L<IO::Pty> which allows you to create a
pseudoterminal for the child process. This is especially useful for application
such as C<bash> and L<ssh>.

This module is currently EXPERIMENTAL, but unlikely to change much.

=head1 EVENTS

=head2 drain

  $run3->on(drain => sub ($run3) { });

Emitted after L</write> has written the whole buffer to the subprocess.

=head2 error

  $run3->on(error => sub ($run3, $str) { });

Emitted when something goes wrong.

=head2 finish

  $run3->on(finish => sub ($run3, @) { });

Emitted when the subprocess has ended. L</error> might be emitted before
L</finish>, but L</finish> will always be emitted at some point after L</start>
as long as the subprocess actually stops. L</status> will contain C<$!> if the
subprocess could not be started or the exit code from the subprocess.

=head2 pty

  $run3->on(pty => sub ($run3, $bytes) { });

Emitted when the subprocess write bytes to L<IO::Pty>. See L</driver> for more
details.

=head2 stderr

  $run3->on(stderr => sub ($run3, $bytes) { });

Emitted when the subprocess write bytes to STDERR.

=head2 stdout

  $run3->on(stdout => sub ($run3, $bytes) { });

Emitted when the subprocess write bytes to STDOUT.

=head2 spawn

  $run3->on(spawn => sub ($run3, @) { });

Emitted in the parent process after the subprocess has been forked.

=head1 ATTRIBUTES

=head2 driver

  $hash_ref = $run3->driver;
  $run3 = $run3->driver({stdin => 'pipe', stdout => 'pipe', stderr => 'pipe'});

Used to set the driver for "pty", "stdin", "stdout" and "stderr". The "pipe" key
is a shortcut for setting "stdin", "stdout" and "stderr" to "pipe" unless
specified.

Examples:

  # Open pipe for STDIN and STDOUT and close STDERR in child process
  $run3->driver({pipe => 1, stderr => 'close'});

  # Create a PTY and attach STDIN to it and open a pipe for STDOUT and STDERR
  $run3->driver({stdin => 'pty', stdout => 'pipe', stderr => 'pipe'});

  # Create a PTY and pipes for STDIN, STDOUT and STDERR
  $run3->driver({pty => 1, stdin => 'pipe', stdout => 'pipe', stderr => 'pipe'});

  # Create a PTY, and require the slave to to be manually closed
  $run3->driver({pty => 1, stdout => 'pipe', close_slave => 0});

  # Create a PTY, but do not make the PTY slave the controlling terminal
  $run3->driver({pty => 1, stdout => 'pipe', make_slave_controlling_terminal => 0});

=head2 ioloop

  $ioloop = $run3->ioloop;
  $run3   = $run3->ioloop(Mojo::IOLoop->singleton);

Holds a L<Mojo::IOLoop> object.

=head1 METHODS

=head2 bytes_waiting

  $int = $run3->bytes_waiting;

Returns how many bytes has been passed on to L</write> buffer, but not yet
written to the child process.

=head2 close

  $run3 = $run3->close($conduit);

Used to close open filehandles. This method can be called in both parent and
child process. C<$conduit> can be:

=over 2

=item * stdin, stdout, stderr

Close STDIN, STDOUT or STDERR in parent or child process. Closing "stdin" is
useful after piping data into a process like C<cat>.

=item * pty, slave

If L</driver> opens a "pty", there will be one filehandle opened for the child
and one for the parent. The actual "pty" can be closed in both parent and child,
while the "slave" can only be closed from the parent process if C<close_slave>
was set to "0" (zero) in L</driver>.

=item * other

This is useful in the child process to close every filehandle that is not
L<STDIN>, L<STDOUT> or L<STDERR>. This is required when opening programs that
does not automatically do this for you, like "telnet":

  $run3->start(sub ($run3, @) {
    $run3->close('other');
    exec telnet => '127.0.0.1';
  });

=back

=head2 exit_status

  $int = $run3->exit_status;

Returns the exit status part of L</status>, which will should be a number from
0 to 255.

=head2 handle

  $fh = $run3->handle($name);

Returns a file handle or undef for C<$name>, which can be "stdin", "stdout",
"stderr" or "pty". This method returns the write or read "end" of the file
handle depending if it is called from the parent or child process.

=head2 kill

  $int = $run3->kill($signal);

Used to send a C<$signal> to the subprocess. Returns C<-1> if no process
exists, C<0> if the process could not be signalled and C<1> if the signal was
successfully sent.

=head2 pid

  $int = $run3->pid;

Process ID of the child after L</start> has successfully started. The PID will
be "0" in the child process and "-1" before the child process was started.

=head2 run_p

  $p = $run3->run_p(sub ($run3) { ... })->then(sub ($run3) { ... });

Will L</start> the subprocess and the promise will be fulfilled when L</finish>
is emitted.

=head2 start

  $run3 = $run3->start(sub ($run3, @) { ... });

Will start the subprocess. The code block passed in will be run in the child
process. C<exec()> can be used if you want to run another program. Example:

  $run3 = $run3->start(sub { exec @my_other_program_with_args });
  $run3 = $run3->start(sub { exec qw(/usr/bin/ls -l /tmp) });

=head2 status

  $int = $run3->status;

Holds the exit status of the program or C<$!> if the program failed to start.
The value includes signals and coredump flags. L</exit_status> can be used
instead to get the exit value from 0 to 255.

=head2 write

  $run3 = $run3->write($bytes);
  $run3 = $run3->write($bytes, sub ($run3) { ... });
  $run3 = $run3->write($bytes, $conduit);
  $run3 = $run3->write($bytes, $conduit, sub ($run3) { ... });

Used to write C<$bytes> to the subprocess. C<$conduit> can be "pty" or "stdin",
and defaults to "stdin". The optional callback will be called on the next
L</drain> event.

=head1 AUTHOR

Jan Henning Thorsen

=head1 COPYRIGHT AND LICENSE

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<https://github.com/jhthorsen/mojo-run3/tree/main/examples>,
L<Mojo::Run3::Util>, L<Mojo::IOLoop::ReadWriteFork>, L<IPC::Run3>.

=cut
