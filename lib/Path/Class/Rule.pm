use 5.008001;
use strict;
use warnings;

package Path::Class::Rule;
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
  return bless { item_filter => sub {1} }, shift;
}

sub add_helper {
  my ($class, $name, $coderef) = @_;
  $class = ref $class || $class;
  if ( ! $class->can($name) ) {
    no strict 'refs';
    *$name = sub {
      my $self = shift;
      my $rule = $coderef->(@_);
      $self->add_rule( $rule )
    };
  }
}

#--------------------------------------------------------------------------#
# object methods
#--------------------------------------------------------------------------#

sub add_rule {
  my ($self, $rule) = @_;
  # XXX rule must be coderef
  if ( my $filter = $self->{item_filter} ) {
    $self->{item_filter} = sub { $filter->(@_) && $rule->(@_) };
  }
  else {
    $self->{item_filter} = $rule;
  }
  return $self;
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
  my $filter = $self->{item_filter};
  my $stash = $self->{stash};
  my %seen;

  return sub {
    LOOP: {
      my $item = shift @queue
        or return;
      if ( ! $opts->{follow_symlinks} ) {
        redo LOOP if -l $item;
      }
      local $_ = $item;
      my ($interest, $prune) = $filter->($item, $stash);
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

my %helpers = (
  is_dir => sub { return sub { $_->is_dir } },
  is_file => sub { return sub { ! $_->is_dir } },
  skip_dirs => sub {
    my @patterns = map { _regexify($_) } @_;
    return sub {
      my $f = shift;
      return (0,1) if $f->is_dir && first { $f =~ $_} @patterns;
      return 1;
    }
  },

);

while ( my ($k,$v) = each %helpers ) {
  __PACKAGE__->add_helper( $k, $v );
}

1;

# ABSTRACT: No abstract given for Path::Class::Rule

=for Pod::Coverage method_names_here

=begin wikidoc

= SYNOPSIS

  use Path::Class::Rule;

= DESCRIPTION

This module might be cool, but you'd never know it from the lack
of documentation.

= USAGE

Good luck!

= SEE ALSO

Maybe other modules do related things.

=end wikidoc

=cut

# vim: ts=2 sts=2 sw=2 et:
