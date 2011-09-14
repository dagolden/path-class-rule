use 5.006;
use strict;
use warnings;
use autodie;
use Test::More 0.92;
use Path::Class;
use File::Temp;
use Test::Deep qw/cmp_deeply/;

use lib 't/lib';
use PCNTest;

use Path::Class::Rule;

#--------------------------------------------------------------------------#

my @tree = qw(
  aaaa.txt
  bbbb.txt
);

my $td = make_tree(@tree);

{
  my $rule = Path::Class::Rule->new->and( sub { die "Evil here" } );
  eval { $rule->all($td) };
  like( $@, qr/^$td: Evil here/, "default error handler dies" );
}

{
  my @msg;
  my $handler = sub { push @msg, [@_]; };
  my $rule = Path::Class::Rule->new->and( sub { die "Evil here" } );
  eval { $rule->all($td, { error_handler => $handler } ) };
  is( $@, '', "error handler catches fatalitis" );
  is( scalar @msg, 3, "saw correct number of Path::Class objects" );
  my ($file, $text) = @{$msg[0]};
  ok( $file->isa('Path::Class::Entity'), "handler gets Path::Class object")
    or diag explain $file;
  is( $file, file($td), "object has file path of error");
  like( $text, qr/^Evil here/, "handler gets message" );
}

done_testing;
# COPYRIGHT
