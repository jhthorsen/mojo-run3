# NAME

Mojo::Run3 - Run a subprocess and read/write to it

# SYNOPSIS

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

    my $run3 = Mojo::Run3->new
      ->driver({pty => 'pty', stdin => 'pipe', stdout => 'pipe', stderr => 'pipe'});

    $run3->once(pty => sub ($run3, $bytes) {
      $run3->write("my-secret-password\n", "pty") if $bytes =~ /password:/;
    });

    $run3->on(stdout => sub ($run3, $bytes) {
      STDOUT->syswrite($bytes);
    });

    $run3->run_p(sub { exec qw(ssh example.com ls -l /tmp) })->wait;

# DESCRIPTION

[Mojo::Run3](https://metacpan.org/pod/Mojo%3A%3ARun3) allows you to fork a subprocess which you can write STDIN to, and
read STDERR and STDOUT without blocking the the event loop.

This module also supports [IO::Pty](https://metacpan.org/pod/IO%3A%3APty) which allows you to create a
pseudoterminal for the child process. This is especially useful for application
such as `bash` and [ssh](https://metacpan.org/pod/ssh).

This module is currently EXPERIMENTAL, but unlikely to change much.

# EVENTS

## drain

    $run3->on(drain => sub ($run3) { });

Emitted after ["write"](#write) has written the whole buffer to the subprocess.

## error

    $run3->on(error => sub ($run3, $str) { });

Emitted when something goes wrong.

## finish

    $run3->on(finish => sub ($run3, @) { });

Emitted when the subprocess has ended. ["error"](#error) might be emitted before
["finish"](#finish), but ["finish"](#finish) will always be emitted at some point after ["start"](#start)
as long as the subprocess actually stops. ["status"](#status) will contain `$!` if the
subprocess could not be started or the exit code from the subprocess.

## pty

    $run3->on(pty => sub ($run3, $bytes) { });

Emitted when the subprocess write bytes to [IO::Pty](https://metacpan.org/pod/IO%3A%3APty). See ["driver"](#driver) for more
details.

## stderr

    $run3->on(stderr => sub ($run3, $bytes) { });

Emitted when the subprocess write bytes to STDERR.

## stdout

    $run3->on(stdout => sub ($run3, $bytes) { });

Emitted when the subprocess write bytes to STDOUT.

## spawn

    $run3->on(spawn => sub ($run3, @) { });

Emitted in the parent process after the subprocess has been forked.

# ATTRIBUTES

## driver

    $hash_ref = $run3->driver;
    $run3 = $self->driver({stdin => 'pipe', stdout => 'pipe', stderr => 'pipe'});

Used to set the driver for "pty", "stdin", "stdout" and "stderr".

Examples:

    # Open pipe for STDIN and STDOUT and close STDERR in child process
    $self->driver({stdin => 'pipe', stdout => 'pipe'});

    # Create a PTY and attach STDIN to it and open a pipe for STDOUT and STDERR
    $self->driver({stdin => 'pty', stdout => 'pipe', stderr => 'pipe'});

    # Create a PTY and pipes for STDIN, STDOUT and STDERR
    $self->driver({pty => 'pty', stdin => 'pipe', stdout => 'pipe', stderr => 'pipe'});

    # Create a PTY, but do not make the PTY slave the controlling terminal
    $self->driver({pty => 'pty', stdout => 'pipe', make_slave_controlling_terminal => 0});

    # It is not supported to set "pty" to "pipe"
    $self->driver({pty => 'pipe'});

## ioloop

    $ioloop = $run3->ioloop;
    $run3   = $run3->ioloop(Mojo::IOLoop->singleton);

Holds a [Mojo::IOLoop](https://metacpan.org/pod/Mojo%3A%3AIOLoop) object.

# METHODS

## bytes\_waiting

    $int = $run3->bytes_waiting;

Returns how many bytes has been passed on to ["write"](#write) buffer, but not yet
written to the child process.

## close

    $run3 = $run3->close('other');
    $run3 = $run3->close('stdin');

Can be used to close `STDIN` or other filehandles that are not in use in a sub
process.

Closing "stdin" is useful after piping data into a process like `cat`.

Here is an example of closing "other":

    $run3->start(sub ($run3, @) {
      $run3->close('other');
      exec telnet => '127.0.0.1';
    });

Closing "other" is currently EXPERIMENTAL and might be changed later on, but it
is unlikely it will get removed.

## exit\_status

    $int = $run3->exit_status;

Returns the exit status part of ["status"](#status), which will should be a number from
0 to 255.

## handle

    $fh = $run3->handle($name);

Returns a file handle or undef for `$name`, which can be "stdin", "stdout",
"stderr" or "pty". This method returns the write or read "end" of the file
handle depending if it is called from the parent or child process.

## kill

    $int = $run3->kill($signal);

Used to send a `$signal` to the subprocess. Returns `-1` if no process
exists, `0` if the process could not be signalled and `1` if the signal was
successfully sent.

## pid

    $int = $run3->pid;

Process ID of the child after ["start"](#start) has successfully started. The PID will
be "0" in the child process and "-1" before the child process was started.

## run\_p

    $p = $run3->run_p(sub ($run3) { ... })->then(sub ($run3) { ... });

Will ["start"](#start) the subprocess and the promise will be fulfilled when ["finish"](#finish)
is emitted.

## start

    $run3 = $run3->start(sub ($run3, @) { ... });

Will start the subprocess. The code block passed in will be run in the child
process. `exec()` can be used if you want to run another program. Example:

    $run3 = $run3->start(sub { exec @my_other_program_with_args });
    $run3 = $run3->start(sub { exec qw(/usr/bin/ls -l /tmp) });

## status

    $int = $run3->status;

Holds the exit status of the program or `$!` if the program failed to start.
The value includes signals and coredump flags. ["exit\_status"](#exit_status) can be used
instead to get the exit value from 0 to 255.

## write

    $run3 = $run3->write($bytes);
    $run3 = $run3->write($bytes, sub ($run3) { ... });
    $run3 = $run3->write($bytes, $conduit);
    $run3 = $run3->write($bytes, $conduit, sub ($run3) { ... });

Used to write `$bytes` to the subprocess. `$conduit` can be "pty" or "stdin",
and defaults to "stdin". The optional callback will be called on the next
["drain"](#drain) event.

# AUTHOR

Jan Henning Thorsen

# COPYRIGHT AND LICENSE

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

# SEE ALSO

[https://github.com/jhthorsen/mojo-run3/tree/main/examples](https://github.com/jhthorsen/mojo-run3/tree/main/examples),
[Mojo::Run3::Util](https://metacpan.org/pod/Mojo%3A%3ARun3%3A%3AUtil), [Mojo::IOLoop::ReadWriteFork](https://metacpan.org/pod/Mojo%3A%3AIOLoop%3A%3AReadWriteFork), [IPC::Run3](https://metacpan.org/pod/IPC%3A%3ARun3).
