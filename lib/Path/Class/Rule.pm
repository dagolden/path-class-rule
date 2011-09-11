use 5.008001;
use strict;
use warnings;

package Path::Class::Rule;
# ABSTRACT: File finder using Path::Class
# VERSION

# Dependencies
use autodie 2.00;
use namespace::autoclean;
use Carp;
use List::Util qw/first/;
use Number::Compare;
use Path::Class;
use Scalar::Util qw/blessed reftype/;
use Text::Glob qw/glob_to_regex/;

#--------------------------------------------------------------------------#
# constructors and meta methods
#--------------------------------------------------------------------------#

sub new {
  my $class = shift;
  return bless { rules => [ sub {1} ] }, ref $class || $class;
}

sub clone {
  my $self = shift;
  return bless { %$self }, ref $self;
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
# iteration methods
#--------------------------------------------------------------------------#

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
# logic methods
#--------------------------------------------------------------------------#

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
      $result = $rule->($item) || 0;
      return $result if $result; # want to shortcut on "0 but true"
    }
    return $result;
  };
}

sub test {
  my ($self, $item) = @_;
  my $result;
  for my $rule ( @{$self->{rules}} ) {
    $result = $rule->($item) || 0;
    return $result if ! (0+$result); # want to shortcut on "0 but true"
  }
  return $result;
}

#--------------------------------------------------------------------------#
# private methods
#--------------------------------------------------------------------------#

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

#--------------------------------------------------------------------------#
# built-in helpers
#--------------------------------------------------------------------------#

sub _regexify {
  my $re = shift;
  return ref($_) && reftype($_) eq 'REGEXP' ? $_ : glob_to_regex($_);
}

my %simple_helpers = (
  is_dir => sub { $_->is_dir },
  is_file => sub { ! $_->is_dir },
);

my %complex_helpers = (
  name => sub {
    Carp::croak("No patterns provided to 'skip_dirs'") unless @_;
    my @patterns = map { _regexify($_) } @_;
    return sub {
      my $f = shift;
      my $name = $f->relative($f->parent);
      return (first { $name =~ $_} @patterns ) ? 1 : 0;
    }
  },
  skip_dirs => sub {
    Carp::croak("No patterns provided to 'skip_dirs'") unless @_;
    my $name_check = Path::Class::Rule->new->name(@_);
    return sub {
      my $f = shift;
      return "0 but true" if $f->is_dir && $name_check->test($f);
      return 1; # otherwise, like a null rule
    }
  },
);

while ( my ($k,$v) = each %complex_helpers ) {
  __PACKAGE__->add_helper( $k, $v );
}

while ( my ($k,$v) = each %simple_helpers ) {
  __PACKAGE__->add_helper( $k, sub { return $v } );
}

# X_tests adapted from File::Find::Rule
my %X_tests = (
    -r  =>  readable           =>  -R  =>  r_readable      =>
    -w  =>  writeable          =>  -W  =>  r_writeable     =>
    -w  =>  writable           =>  -W  =>  r_writable      =>
    -x  =>  executable         =>  -X  =>  r_executable    =>
    -o  =>  owned              =>  -O  =>  r_owned         =>

    -e  =>  exists             =>  -f  =>  file            =>
    -z  =>  empty              =>  -d  =>  directory       =>
    -s  =>  nonempty           =>  -l  =>  symlink         =>
                               =>  -p  =>  fifo            =>
    -u  =>  setuid             =>  -S  =>  socket          =>
    -g  =>  setgid             =>  -b  =>  block           =>
    -k  =>  sticky             =>  -c  =>  character       =>
                               =>  -t  =>  tty             =>
    -M  =>  modified                                       =>
    -A  =>  accessed           =>  -T  =>  ascii           =>
    -C  =>  changed            =>  -B  =>  binary          =>
);

while ( my ($op,$name) = each %X_tests ) {
  my $coderef = eval "sub { $op \$_ }";
  my $not_coderef = eval "sub { ! $op \$_ }";
  __PACKAGE__->add_helper( $name, sub { return $coderef } );
  __PACKAGE__->add_helper( "not_$name", sub { return $not_coderef } );
}

# stat tests adapted from File::Find::Rule
my @stat_tests = qw(
  dev ino mode nlink uid gid rdev size atime mtime ctime blksize blocks
);

for my $name ( @stat_tests ) {
  my $coderef = sub {
    Carp::croak("The '$name' test requires a single argument") unless @_ == 1;
    my $comparator = Number::Compare->new(shift);
    return sub { return $comparator->($_->stat->$name) };
  };
  __PACKAGE__->add_helper( $name, $coderef );
}

1;

=for Pod::Coverage method_names_here

=head1 SYNOPSIS

  use Path::Class::Rule;

  my $rule = Path::Class::Rule->new; # match anything
  $rule->is_file->size(">10k");      # add/chain rules

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

  my $rule = Path::Class::Rule->new;

Creates a new rule object that matches any file or directory.  It takes
no arguments.

=head2 C<clone>

  my $rule2 = $rule1->clone;

Creates a copy of a rule.

=head2 C<all>

  my @matches = $rule->all( @dir, \%options );

Returns a list of L<Path::Class> objects that match the rule.  It takes
as arguments a list of directories to search and an optional hash reference
of control options.  If no search directories are provided, the current
directory is used (C<".">).  Valid options include:

=for :list
* C<depthfirst> -- Controls order of results.  Valid values are "1"
(post-order, depth-first search), "0" (breadth-first search) or
"-1" (pre-order, depth-first search). Default is 0.  
* C<follow_symlinks> -- Follow directory symlinks when true. Default is 1.

Following symlinks may result in files be returned more than once;
turning it off requires overhead of a stat call. Set this appropriate
to your needs.

B<Note>: each directory I<path> will only be entered once.  Due to symlinks,
this could mean a physical directory is entered more than once.

XXX Not yet protected against loops -- how do we do that?

=head2 C<iter>

  my $next = $rule->iter( @dirs, \%options);
  while ( my $file = $next->() ) {
    ...
  }

Creates a coderef iterator that returns a single L<Path::Class> object
when dereferenced.  It takes the same arguments and has the same behaviors
as the C<all> method.

This iterator is "lazy" -- results are not pre-computed.  The C<all> method
uses C<iter> internally to fetch all results.

=head2 C<test>

  if ( $rule->test( $path ) ) { ... }

Test a file path against a rule.  Used internally, but provided should
someone want to create their own, custom iteration routine.

=head1 RULES

XXX define what a rule is (i.e. coderef or another rule object)

=head2 Logic rules

XXX and, or, not (not implented)

=head2 File type rules

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
