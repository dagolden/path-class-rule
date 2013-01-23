use strict;
use warnings;

package Path::Class::Rule;
# ABSTRACT: Iterative, recursive file finder with Path::Class
# VERSION

use Path::Iterator::Rule 0.002; # new _children API
our @ISA = qw/Path::Iterator::Rule/;

use Path::Class;
use namespace::clean;

sub _objectify {
    my $self = shift;
    my $path = "" . shift;
    return -d $path ? dir($path) : file($path);
}

sub _children {
    my $self = shift;
    my $path = shift;
    return map { [ $_->basename, $_ ] } $path->children;
}

1;

=head1 SYNOPSIS

  use Path::Class::Rule;

  my $rule = Path::Class::Rule->new; # match anything
  $rule->file->size(">10k");         # add/chain rules

  # iterator interface
  my $next = $rule->iter( @dirs );
  while ( my $file = $next->() ) {
    ...
  }

  # list interface
  for my $file ( $rule->all( @dirs ) ) {
    ...
  }

=head1 DESCRIPTION

This module iterates over files and directories to identify ones matching a
user-defined set of rules.  The API is based heavily on L<File::Find::Rule>,
but with more explicit distinction between matching rules and options that
influence how directories are searched.  A C<Path::Class::Rule> object is a
collection of rules (match criteria) with methods to add additional criteria.
Options that control directory traversal are given as arguments to the method
that generates an iterator.

As of version 0.016, this is now a thin subclass of L<Path::Iterator::Rule>
that operates on and returns L<Path::Class> objects instead of bare file paths.

See that module for details on features and usage.

=head1 EXTENDING

This module may be extended in the same way as C<Path::Iterator::Rule>, but
test subroutines receive C<Path::Class> objects instead of strings.

Consider whether you should extend C<Path::Iterator::Rule> or C<Path::Class::Rule>.
Extending this module specifically is recommended if your tests rely on having
a C<Path::Class> object.

=head1 LEXICAL WARNINGS

If you run with lexical warnings enabled, C<Path::Iterator::Rule> will issue
warnings in certain circumstances (such as a read-only directory that must be
skipped).  To disable these categories, put the following statement at the
correct scope:

  no warnings 'Path::Iterator::Rule';

=cut

# vim: ts=4 sts=4 sw=4 et:
