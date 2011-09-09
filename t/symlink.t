use 5.006;
use strict;
use warnings;
use autodie;
use Test::More 0.92;
use Path::Class;
use File::Temp;
use Test::Deep qw/cmp_deeply/;
use File::pushd qw/pushd/;
use Config;

use lib 't/lib';
use PCNTest;

use Path::Class::Rule;

#--------------------------------------------------------------------------#

plan skip_all => "No symlink support"
  unless $Config{d_symlink};

#--------------------------------------------------------------------------#

{
  my @tree = qw(
    aaaa.txt
    bbbb.txt
    cccc/dddd.txt
    cccc/eeee/ffff.txt
    gggg.txt
  );

  my @follow = qw(
    .
    aaaa.txt
    bbbb.txt
    cccc
    gggg.txt
    pppp
    qqqq.txt
    cccc/dddd.txt
    cccc/eeee
    pppp/ffff.txt
    cccc/eeee/ffff.txt
  );

  my @nofollow = qw(
    .
    aaaa.txt
    bbbb.txt
    cccc
    gggg.txt
    cccc/dddd.txt
    cccc/eeee
    cccc/eeee/ffff.txt
  );

  my $td = make_tree(@tree);

  symlink dir($td,'cccc','eeee'), dir($td,'pppp');
  symlink file($td,'aaaa.txt'), file($td,'qqqq.txt');

  my ($iter, @files);
  my $rule = Path::Class::Rule->new;

  @files = map  { $_->relative($td)->stringify }
                $rule->all($td);
  cmp_deeply( \@files, \@follow, "Follow symlinks")
    or diag explain { got => \@files, expected => \@follow };

  @files = map  { $_->relative($td)->stringify }
                $rule->all({follow_symlinks => 0}, $td);
  cmp_deeply( \@files, \@nofollow, "Don't follow symlinks")
    or diag explain { got => \@files, expected => \@nofollow };

}

done_testing;
# COPYRIGHT
