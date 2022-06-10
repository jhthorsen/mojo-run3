# NAME

Mojo::Run3 - Run a subprocess and read/write to it

# SYNOPSIS

TODO

# DESCRIPTION

[Mojo::Run3](https://metacpan.org/pod/Mojo%3A%3ARun3) allows you to fork a subprocess which you can ["write"](#write) STDIN to,
and ["read"](#read) STDERR and STDOUT, without blocking the the event loop.

# ATTRIBUTES

## ioloop

    $ioloop = $run->ioloop;
    $run    = $run->ioloop(Mojo::IOLoop->singleton);

## pid

    $int = $run->pid;

## status

    $int = $run->status;

# METHODS

## close

    $run = $run->close('stdin');

## exit\_code

    $int = $run->exit_code;

## kill

    $int = $run->kill($signal);

## run\_p

    $run = $run->run_p(sub ($run, $fh) { ... });

## start

    $run = $run->start(sub ($run, $fh) { ... });

## signal

    $int = $run->signal;

## write

    $run = $run->write($bytes);
    $run = $run->write($bytes, sub ($run) { ... });

# AUTHOR

Jan Henning Thorsen

# COPYRIGHT AND LICENSE

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

# SEE ALSO

[Mojo::IOLoop::ReadWriteFork](https://metacpan.org/pod/Mojo%3A%3AIOLoop%3A%3AReadWriteFork), [IPC::Run3](https://metacpan.org/pod/IPC%3A%3ARun3).
