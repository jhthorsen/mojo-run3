use Mojo::Base -strict;
use Mojo::Run3;
use Test::More;

my ($bash) = grep { -x "$_/bash" } split /:/, $ENV{PATH} || '';
plan skip_all => 'bash was not found' unless $bash;

subtest 'bash' => sub {
  my $run3 = Mojo::Run3->new(driver => 'pty');
  $run3->ioloop->timer(2 => sub { $run3->close('stdin')->kill(9) });

  my ($sent, %read);
  $run3->on(pty    => sub { $read{pty}    .= $_[1] });
  $run3->on(stderr => sub { $read{stderr} .= $_[1] });
  $run3->on(stdout => sub { $read{stdout} .= $_[1] });
  $run3->write("ls -F -l / && exit\n");
  $run3->run_p(sub { exec qw(bash -i) })->wait;
  ok $run3->pid > 0, 'pid';
  like $read{stdout}, qr{\bdev/$}m, 'stdout';
};

done_testing;
