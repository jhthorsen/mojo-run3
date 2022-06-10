use Mojo::Base -strict;
use Mojo::Run3;
use Test::More;

my $bash = '/bin/bash';
plan skip_all => "$bash was not found" unless -x $bash;

subtest 'bash' => sub {
  my $run3 = Mojo::Run3->new(driver => 'pty');
  $run3->ioloop->timer(2 => sub { $run3->close('stdin')->kill(9) });

  my ($sent, %read);
  $run3->on(
    read => sub {
      my ($run, $bytes, $conduit) = @_;
      $read{$conduit} .= $bytes;
      $run3->write("ls -l / && exit\n") unless $sent++;
    }
  );

  $run3->run_p(sub { exec qw(bash -i) })->wait;
  ok $run3->pid > 0, 'pid';
  like $read{stdout}, qr{\bdev/?\b$}m, 'stdout';
};

done_testing;
