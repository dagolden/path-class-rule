use 5.008001;
use strict;
use warnings;

package Path::Class::Rule;
# ABSTRACT: File finder using Path::Class
# VERSION

# Dependencies
use autodie 2.00;
use Path::Class;
use Scalar::Util qw/blessed reftype/;
use List::Util qw/first/;

#--------------------------------------------------------------------------#
# class methods
#--------------------------------------------------------------------------#

sub new {
  my $class = shift;
  return bless { rules => [ sub {1} ] }, ref $class || $class;
}

sub add_helper {
  my ($class, $name, $coderef) = @_;
  $class = ref $class || $class;
  if ( ! $class->can($name) ) {
    no strict 'refs';
    *$name = sub {
      my $self = shift;
      my $rule = $coderef->(@_);
      $self->and( $rule )
    };
  }
}

#--------------------------------------------------------------------------#
# object methods
#--------------------------------------------------------------------------#

sub clone {
  my $self = shift;
  return bless { %$self }, ref $self;
}

sub test {
  my ($self, $item) = @_;
  my $result;
  for my $rule ( @{$self->{rules}} ) {
    $result = $rule->($item);
    return $result if ! $result; # want to shortcut but return "0 but true"
  }
  return $result;
}

sub _rulify {
  my ($self, $method, @args) = @_;
  my @rules;
  for my $arg ( @args ) {
    my $rule;
    if ( blessed($arg) && $arg->isa("Path::Class::arg") ) {
      $rule = sub { $rule->test(@_) };
    }
    elsif ( ref($arg) eq 'CODE' ) {
      $rule = $arg;
    }
    else {
      Carp::croak("Argument to ->and() must be coderef or Path::Class::Rule")
    }
    push @rules, $rule
  }
  return @rules
}

sub and {
  my $self = shift;
  push @{$self->{rules}}, $self->_rulify("and", @_);
  return $self;
}

sub or {
  my $self = shift;
  my @rules = $self->_rulify("or", @_);
  return sub {
    my $item = shift;
    my $result;
    for my $rule ( @rules ) {
      $result = $rule->($item);
      return $result if $result; # want to shortcut but return "0 but true"
    }
    return $result;
  };
}

my %defaults = (
  follow_symlinks => 1,
  depthfirst => 0,
);

sub iter {
  my $self = shift;
  my $args =  ref($_[0])  && !blessed($_[0])  ? shift
            : ref($_[-1]) && !blessed($_[-1]) ? pop : {};
  my $opts = { %defaults, %$args };
  my @queue = map { dir($_) } @_ ? @_ : '.';
  my %seen;

  return sub {
    LOOP: {
      my $item = shift @queue
        or return;
      if ( ! $opts->{follow_symlinks} ) {
        redo LOOP if -l $item;
      }
      local $_ = $item;
      my $interest = $self->test($item);
      my $prune = $interest && ! (0+$interest); # capture "0 but true"
      $interest += 0;                           # then ignore "but true"
      if ($item->is_dir && ! $seen{$item}++ && ! $prune) {
        if ( $opts->{depthfirst} ) {
          my @next = sort $item->children;
          push @next, $item if $opts->{depthfirst} < 0; # repeat for postorder
          unshift @queue, @next;
          redo LOOP if $opts->{depthfirst} < 0;
        }
        else {
          push @queue, sort $item->children;
        }
      }
      return $item
        if $interest;
      redo LOOP;
    }
  };
}

sub all {
  my $self = shift;
  my $iter = $self->iter(@_);
  my @results;
  while ( my $item = $iter->() ) {
    push @results, $item;
  }
  return @results;
}

#--------------------------------------------------------------------------#
# common helpers
#--------------------------------------------------------------------------#

sub _regexify {
  my $re = shift;
  return ref($_) && reftype($_) eq 'REGEXP' ? $_ : qr/\b\Q$_\E\b/;
}

my %simple_helpers = (
  is_dir => sub { $_->is_dir },
  is_file => sub { ! $_->is_dir },
);

my %complex_helpers = (
  skip_dirs => sub {
    my @patterns = map { _regexify($_) } @_;
    return sub {
      my $f = shift;
      return "0 but true" if $f->is_dir && first { $f =~ $_} @patterns;
      return 1;
    }
  },
);

while ( my ($k,$v) = each %complex_helpers ) {
  __PACKAGE__->add_helper( $k, $v );
}

while ( my ($k,$v) = each %simple_helpers ) {
  __PACKAGE__->add_helper( $k, sub { return $v } );
}

1;

=for Pod::Coverage method_names_here

=head1 SYNOPSIS

  use Path::Class::Rule;

  my $rule = Path::Class::Rule->new; # match anything
  $rule->is_file->not_empty;         # add/chain rules

  # iterator interface
  my $next = $rule->iter( @dirs, \%options);
  while ( my $file = $next->() ) {
    ...
  }

  # list interface
  for my $file ( $rule->all( @dirs, \%options ) {
    ...
  }

=head1 DESCRIPTION

There are many other file finding modules out there.  They all have various
features/deficiencies, depending on one's preferences and needs.  Here are
some features of this one:

=for :list
* uses (lazy) iterators
* returns L<Path::Class> objects
* custom rules are given L<Path::Class> objects
* breadth-first (default) or pre- or post-order depth-first
* follows symlinks (by default, but can be disabled)
* provides an API for extensions
* doesn't chdir during operation

=head1 USAGE

=head2 C<new>

=head2 C<all>

=head2 C<clone>

=head2 C<iter>

=head2 C<test>

=head1 RULES

=head2 C<and>

=head2 C<or>

=head2 C<is_file>

=head2 C<is_dir>

=head2 C<skip_dirs>

=head1 EXTENDING

XXX talk about how to extend this with new rules/helpers, e.g.

=head2 C<add_helper>

  package Path::Class::Rule::Foo;
  use Path::Class::Rule;
  Path::Class::Rule->add_helper(
    is_foo => sub {
      my @args = @_; # can use to customize rule
      return sub {
        my ($item) = shift;
        return $item->basename =~ /^foo$/;
      }
    }
  );

XXX talk about how to prune with "0 but true"

=head1 SEE ALSO

Here is an (incomplete) list of alternatives, with some comparison commentary.

XXX should I make a table of features by module?  maybe.

=head2 File::Find based modules

L<File::Find> is part of the Perl core.  It requires the user to write a
callback function to process each node of the search.  Callbacks must use
global variables to determine the current node.  It only supports depth-first
search (both pre- and post-order). It supports pre- and post-processing
callbacks; the former is required for sorting files to process in a directory.

L<File::Find::Rule> is an object-oriented wrapper around L<File::Find>.  It
provides a number of helper functions and there are many more
C<File::Find::Rule::*> modules on CPAN with additional helpers.  It provides
an iterator interface, but precomputes all the results.

=head2 Path::Class based modules

=head2 File::Next

=head2 File::Find::Node
=for :list
* L<File::Find>
* L<File::Find::Node>
* L<File::Find::Rule>
* L<File::Finder>
* L<File::Next>
* L<Path::Class::Iterator>

=cut

# vim: ts=2 sts=2 sw=2 et:
