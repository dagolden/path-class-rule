use 5.006;
use strict;
use warnings;
use Test::More 0.92;
use Path::Class;
use File::Temp;
use Test::Deep qw/cmp_deeply/;
use File::pushd qw/pushd/;

use lib 't/lib';
use PCNTest;

use Path::Class::Rule;

#--------------------------------------------------------------------------#

{
  my @tree = qw(
    aaaa.txt
    bbbb.txt
    cccc/dddd.txt
    cccc/eeee/ffff.txt
    gggg.txt
  );

  my @breadth = qw(
    aaaa.txt
    bbbb.txt
    gggg.txt
    dddd.txt
    ffff.txt
  );
  
  my @depth = qw(
    aaaa.txt
    bbbb.txt
    dddd.txt
    ffff.txt
    gggg.txt
  );

  my $td = make_tree(@tree);

  my ($iter, @files);
  my $rule = Path::Class::Rule->new->is_file;

  @files = ();
  @files = map { $_->basename } $rule->all({depthfirst => 0}, $td);
  cmp_deeply( \@files, \@breadth, "Breadth first iteration");

  @files = ();
  @files = map { $_->basename } $rule->all({depthfirst => 1}, $td);
  cmp_deeply( \@files, \@depth, "Depth first iteration");

}

done_testing;
# COPYRIGHT
