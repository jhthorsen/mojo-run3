# NAME

Mojo::Run3 - Run a subprocess and read/write to it

# SYNOPSIS

    use Mojo::Base -strict, -signatures;
    use Mojo::Run3;
    use IO::Handle;

    my $run3 = Mojo::Run3->new;
    $run3->on(stdout => sub ($run3, $bytes) {
      STDOUT->syswrite($bytes);
    });

    $run3->run_p(sub { exec qw(/usr/bin/ls -l /tmp) })->wait;

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

    $run3->on(finish => sub ($run3) { });

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

    $run3->on(spawn => sub ($run3) { });

Emitted in the parent process after the subprocess has been forked.

# ATTRIBUTES

## driver

    $str  = $run3->driver;
    $run3 = $run3->driver('pipe');

Can be set to "pipe" (default) or "pty" to run the child process inside a
pseudoterminal, using [IO::Pty](https://metacpan.org/pod/IO%3A%3APty).

The "pty" will be the [controlling terminal](https://metacpan.org/pod/IO%3A%3APty#make_slave_controlling_terminal)
of the child process and the slave will be closed in the parent process.
If further setup of the pty should be done, it must be done in the child
process. Example:

    $run3->start(sub ($pty3) {
      my $pty = $pty3->handle('stdin'); # stdin is a IO::Tty object
      $pty->set_winsize($row, $col, $xpixel, $ypixel);
      $pty->set_raw;
      exec qw(ssh -t server.example.com);
    });

## ioloop

    $ioloop = $run3->ioloop;
    $run3   = $run3->ioloop(Mojo::IOLoop->singleton);

Holds a [Mojo::IOLoop](https://metacpan.org/pod/Mojo%3A%3AIOLoop) object.

# METHODS

## close

    $run3 = $run3->close('stdin');

Can be used to close `STDIN`. This is useful after piping data into a process
like `cat`.

## exit\_status

    $int = $run3->exit_status;

Returns the exit status part of ["status"](#status), which will should be a number from
0 to 255.

## handle

    $fh = $run3->handle($name);

Returns a file handle or undef from `$name`, which can be "stdin", "stdout",
"stderr" or "pty". This method returns the write or read "end" of the file
handle depending if it is called from the parent or child process.

## kill

    $int = $run3->kill($signal);

Used to send a `$signal` to the subprocess. Returns `-1` if no process
exists, `0` if the process could not be signalled and `1` if the signal was
successfully sent.

## pid

    $int = $run3->pid;

Process ID of the subprocess after ["start"](#start) has successfully started.

## run\_p

    $p = $run3->run_p(sub ($run3) { ... })->then(sub ($run3) { ... });

Will ["start"](#start) the subprocess and the promise will be fulfilled when ["finish"](#finish)
is emitted.

## start

    $run3 = $run3->start(sub ($run3, @) { ... });

Will start the subprocess. The code block passed in will be run in the child
process. The code below can be used if you want to run another program:

    $run3 = $run3->start(sub { exec @my_other_program_with_args });
    $run3 = $run3->start(sub { exec qw(/usr/bin/ls -l /tmp) });

## status

    $int = $run3->status;

Holds the exit status of the program or `$!` if the program failed to start.
The value includes signals and coredump flags, but ["exit\_status"](#exit_status) can be used
be used to get the value from 0 to 255.

## write

    $run3 = $run3->write($bytes);
    $run3 = $run3->write($bytes, sub ($run3) { ... });

Used to write `$bytes` to the subprocess. The optional callback will be called
on the next ["drain"](#drain) event.

# AUTHOR

Jan Henning Thorsen

# COPYRIGHT AND LICENSE

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

# SEE ALSO

[Mojo::IOLoop::ReadWriteFork](https://metacpan.org/pod/Mojo%3A%3AIOLoop%3A%3AReadWriteFork), [IPC::Run3](https://metacpan.org/pod/IPC%3A%3ARun3).
