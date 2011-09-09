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
  my ($rule, @files);

  my $td = make_tree(qw(
    data/file1.txt
  ));

  my $file = file($td, 'data', 'file1.txt');
  
  # chmod a-rwx
  chmod 0777, $file;

  $rule = Path::Class::Rule->new->is_file;
  @files = ();
  @files = $rule->all($td);
  is( scalar @files, 1, "Any file") or diag explain \@files;

  $rule = Path::Class::Rule->new->is_file->readable;
  @files = ();
  @files = $rule->all($td);
  is( scalar @files, 1, "readable") or diag explain \@files;

  $rule = Path::Class::Rule->new->is_file->not_readable;
  @files = ();
  @files = $rule->all($td);
  is( scalar @files, 0, "not_readable") or diag explain \@files;

}

done_testing;
# COPYRIGHT
