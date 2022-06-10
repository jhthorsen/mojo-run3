use Mojo::Base -strict;
use Mojo::Run3;
use Test::More;

subtest 'status' => sub {
  my $run3 = Mojo::Run3->new;
  is $run3->status, -1, 'before finish';
};

subtest 'stdout' => sub {
  my $run3   = Mojo::Run3->new;
  my $stdout = '';
  $run3->on(read => sub { $_[2] eq 'stdout' ? ($stdout .= $_[1]) : diag "STDERR <<< $_[1]" });
  $run3->run_p(sub { print STDOUT "cool beans\n" })->wait;
  is $stdout, "cool beans\n", 'read';
  ok $run3->pid > 0, 'pid';
  is $run3->status, 0, 'status';
};

subtest 'stderr' => sub {
  my $run3   = Mojo::Run3->new;
  my $stderr = '';
  $run3->on(read => sub { $_[2] eq 'stderr' ? ($stderr .= $_[1]) : diag "STDOUT <<< $_[1]" });
  $run3->run_p(sub { print STDERR "cool beans\n" })->wait;
  is $stderr, "cool beans\n", 'read';
  ok $run3->pid > 0, 'pid';
  is $run3->status, 0, 'status';
};

subtest 'stdin' => sub {
  my $run3   = Mojo::Run3->new;
  my $stdout = '';
  $run3->on(read  => sub { $_[2] eq 'stdout' ? ($stdout .= $_[1]) : diag "STDERR <<< $_[1]" });
  $run3->on(spawn => sub { shift->write("cool beans\n") });
  $run3->run_p(sub { print scalar <STDIN> })->wait;
  is $stdout, "cool beans\n", 'read';
  ok $run3->pid > 0, 'pid';
  is $run3->status, 0, 'status';
};

subtest 'kill' => sub {
  my $run3 = Mojo::Run3->new;
  is $run3->kill, -1, 'without pid';

  $run3->on(spawn => sub { shift->kill('TERM') });
  $run3->run_p(sub { exec sleep => 10 })->wait;
  ok $run3->pid > 0, 'pid';
  is $run3->status,       15, 'status';
  is $run3->exit_status,  0,  'exit_status';
  is $run3->status & 127, 15, 'signal';
};

subtest 'close' => sub {
  my $run3 = Mojo::Run3->new;
  ok $run3->close('stdin'), 'noop';

  my $stdout = '';
  $run3->on(read  => sub { $_[2] eq 'stdout' ? ($stdout .= $_[1]) : diag "STDERR <<< $_[1]" });
  $run3->on(spawn => sub { shift->write("ice cool\n")->close('stdin') });
  $run3->run_p(sub { exec qw(cat -) })->wait;
  is $stdout, "ice cool\n", 'read';
  ok $run3->pid > 0, 'pid';
  is $run3->status, 0, 'status';
};

done_testing;
