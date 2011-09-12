use 5.006;
use strict;
use warnings;
use Test::More 0.92;
use Path::Class;
use File::Copy qw/copy/;
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

  my $changes = file($td, 'data', 'Changes');
  copy( file('Changes'), $changes );
  
  $rule = Path::Class::Rule->new->file;

  @files = ();
  @files = $rule->all($td);
  is( scalar @files, 2, "Any file") or diag explain \@files;

  $rule = Path::Class::Rule->new->file->size(">0");
  @files = ();
  @files = $rule->all($td);
  is( $files[0], $changes, "size > 0") or diag explain \@files;

}

done_testing;
# COPYRIGHT
