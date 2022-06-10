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
  $run3->on(stderr => sub { diag "STDERR <<< $_[1]" });
  $run3->on(stdout => sub { $stdout .= $_[1] });
  $run3->run_p(sub { print STDOUT "cool beans\n" })->wait;
  is $stdout, "cool beans\n", 'read';
  ok $run3->pid > 0, 'pid';
  is $run3->status, 0, 'status';
};

subtest 'stderr' => sub {
  my $run3   = Mojo::Run3->new;
  my $stdout = '';
  $run3->on(stderr => sub { $stdout .= $_[1] });
  $run3->run_p(sub { print STDERR "cool beans\n" })->wait;
  is $stdout, "cool beans\n", 'read';
  ok $run3->pid > 0, 'pid';
  is $run3->status, 0, 'status';
};

subtest 'stdin' => sub {
  my $run3   = Mojo::Run3->new;
  my $stdout = '';
  $run3->on(stderr => sub { diag "STDERR <<< $_[1]" });
  $run3->on(stdout => sub { $stdout .= $_[1] });
  $run3->on(spawn  => sub { shift->write("cool beans\n") });
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
  is $run3->status,    15, 'status';
  is $run3->exit_code, 0,  'exit_code';
  is $run3->signal,    15, 'signal';

};

done_testing;
