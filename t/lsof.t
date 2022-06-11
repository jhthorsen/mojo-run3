BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }
use Mojo::Base -strict;
use Mojo::Run3;
use Test::Mojo;
use Test::More;

plan skip_all => 'TEST_LSOF=1' unless $ENV{TEST_LSOF};

eval 'use Test::Memory::Cycle;1' or Mojo::Util::monkey_patch(
  main => memory_cycle_ok => sub {
    skip 'Test::Memory::Cycle';
  }
);

my @drivers = qw(pipe pty);
my $initial = lsof();

for my $driver (@drivers) {
  subtest $driver => sub {
    is lsof(), $initial, 'before new';
    my $run3   = Mojo::Run3->new(driver => $driver);
    my $stdout = '';
    $run3->on(stderr => sub { diag "STDERR <<< $_[1]" });
    $run3->on(stdout => sub { $stdout .= $_[1] });
    $run3->run_p(sub { print lsof() })->wait;
    is $stdout, $initial + 3, 'lsof in child';
    is lsof(),  $initial,     'after run';
    memory_cycle_ok($run3, 'memory cycle');
    undef $run3;
    is lsof(), $initial, 'after undef';
  };
}

is lsof(), $initial, "all done ($initial)";

done_testing;

sub lsof {
  my $n = qx{lsof -p $$ | wc -l};
  return $n =~ m!(\d+)! ? $1 : -1;
}
