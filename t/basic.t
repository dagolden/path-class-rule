use 5.006;
use strict;
use warnings;
use Test::More 0.92;
use Path::Class;
use File::Temp;
use File::pushd qw/pushd/;

use lib 't/lib';
use PCNTest;

use Path::Class::Rule;

#--------------------------------------------------------------------------#

{
  my $td = make_tree(qw(
    empty/
    data/file1.txt
  ));

  my ($iter, @files);
  my $rule = Path::Class::Rule->new->is_file;

  $iter = $rule->iter($td);

  @files = ();
  while ( my $f = $iter->() ) {
    push @files, $f;
  }

  is( scalar @files, 1, "Iterator: one file");

  @files = ();
  @files = $rule->all($td);

  is( scalar @files, 1, "All: one file");

  $rule = Path::Class::Rule->new->is_dir;
  @files = ();
  @files = $rule->all($td);

  is( scalar @files, 3, "All: 3 directories");

  my $wd = pushd($td);

  @files = ();
  @files = $rule->all();
  is( scalar @files, 3, "All w/ cwd: 3 directories");

  $rule->skip_dirs(qw/data/);
  @files = ();
  @files = $rule->all();
  is( scalar @files, 2, "All w/ prune: 2 directories");
}

done_testing;
# COPYRIGHT
