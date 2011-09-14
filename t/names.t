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
  lib/Foo.pm
  lib/Foo.pod
  t/test.t
);

my $td = make_tree(@tree);

{
  my $rule = Path::Class::Rule->new->name('Foo');
  my $expected = [ ];
  my @files = map { $_->relative($td)->stringify } $rule->all($td);
  cmp_deeply( \@files, $expected, "name('Foo') empty match")
    or diag explain { got => \@files, expected => $expected };
}

{
  my $rule = Path::Class::Rule->new->name('Foo.*');
  my $expected = [qw(
    lib/Foo.pm
    lib/Foo.pod
  )];
  my @files = map { $_->relative($td)->stringify } $rule->all($td);
  cmp_deeply( \@files, $expected, "name('Foo.*') match")
    or diag explain { got => \@files, expected => $expected };
}

{
  my $rule = Path::Class::Rule->new->name(qr/Foo/);
  my $expected = [qw(
    lib/Foo.pm
    lib/Foo.pod
  )];
  my @files = map { $_->relative($td)->stringify } $rule->all($td);
  cmp_deeply( \@files, $expected, "name(qr/Foo/) match")
    or diag explain { got => \@files, expected => $expected };
}

{
  my $rule = Path::Class::Rule->new->name("*.pod", "*.pm");
  my $expected = [qw(
    lib/Foo.pm
    lib/Foo.pod
  )];
  my @files = map { $_->relative($td)->stringify } $rule->all($td);
  cmp_deeply( \@files, $expected, "name('*.pod', '*.pm') match")
    or diag explain { got => \@files, expected => $expected };
}

{
  my $rule = Path::Class::Rule->new->iname(qr/foo/);
  my $expected = [qw(
    lib/Foo.pm
    lib/Foo.pod
  )];
  my @files = map { $_->relative($td)->stringify } $rule->all($td);
  cmp_deeply( \@files, $expected, "iname(qr/foo/) match")
    or diag explain { got => \@files, expected => $expected };
}

{
  my $rule = Path::Class::Rule->new->iname('foo.*');
  my $expected = [qw(
    lib/Foo.pm
    lib/Foo.pod
  )];
  my @files = map { $_->relative($td)->stringify } $rule->all($td);
  cmp_deeply( \@files, $expected, "iname('foo.*') match")
    or diag explain { got => \@files, expected => $expected };
}

done_testing;
# COPYRIGHT
