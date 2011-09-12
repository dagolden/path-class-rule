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
    *{"not_$name"} = sub {
      my $self = shift;
      my $rule = $coderef->(@_);
      $self->not( $rule )
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
  my $coderef = sub {
    my $item = shift;
    my $result;
    for my $rule ( @rules ) {
      $result = $rule->($item) || 0;
      return $result if $result; # want to shortcut on "0 but true"
    }
    return $result;
  };
  return $self->and( $coderef );
}

sub not {
  my $self = shift;
  my @rules = $self->_rulify("not", @_);
  my $obj = $self->new->and(@rules);
  my $coderef = sub {
    my $item = shift;
    my $result = $obj->test($item);
    # XXX what to do about "0 but true"? Ignore it?
    return $result ? "0" : "1";
  };
  return $self->and( $coderef );
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
    if ( blessed($arg) && $arg->isa("Path::Class::Rule") ) {
      $rule = sub { $arg->test(@_) };
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
  __PACKAGE__->add_helper( $name, sub { return $coderef } );
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
influence how directories are searched.

Generally speaking, a C<Path::Class::Rule> object is a collection of rules
(match criteria) with methods to add additional criteria.  Options that control
directory traversal are given as arguments to the method that generates an
iterator.

Here is a summary of features for comparison to other file finding modules:

=for :list
* provides many "helper" methods for specifying rules
* offers (lazy) iterator and flattened list interfaces
* returns L<Path::Class> objects
* custom rules implemented with callbacks
* breadth-first (default) or pre- or post-order depth-first searching
* follows symlinks (by default, but can be disabled)
* doesn't chdir during operation
* provides an API for extensions

=head1 USAGE

=head2 Constructors

=head3 C<new>

  my $rule = Path::Class::Rule->new;

Creates a new rule object that matches any file or directory.  It takes
no arguments.

=head3 C<clone>

  my $common      = Path::Class::Rule->new->is_file->not_empty;
  my $big_files   = $common->clone->size(">1MB");
  my $small_files = $common->clone->size("<10K");

Creates a copy of a rule object.  Useful for customizing different
rule objects against a common base.

=head2 Matching and iteration

=head3 C<iter>

  my $next = $rule->iter( @dirs, \%options);
  while ( my $file = $next->() ) {
    ...
  }

Creates a coderef iterator that returns a single L<Path::Class> object when
dereferenced.This iterator is "lazy" -- results are not pre-computed.

It takes as arguments a list of directories to search and an optional hash
reference of control options.  If no search directories are provided, the
current directory is used (C<".">).  Valid options include:

=for :list
* C<depthfirst> -- Controls order of results.  Valid values are "1"
(post-order, depth-first search), "0" (breadth-first search) or
"-1" (pre-order, depth-first search). Default is 0.
* C<follow_symlinks> -- Follow directory symlinks when true. Default is 1.

Following symlinks may result in files be returned more than once;
turning it off requires overhead of a stat call. Set this appropriate
to your needs.

B<Note>: each directory path will only be entered once.  Due to symlinks,
this could mean a physical directory is entered more than once.

The L<Path::Class> objects inspected and returned will be relative to the
search directories provided.  If these are absolute, then the objects returned
will have absolute paths.  If these are relative, then the objects returned
will have relative paths.

=head3 C<all>

  my @matches = $rule->all( @dir, \%options );

Returns a list of L<Path::Class> objects that match the rule.  It takes the
same arguments and has the same behaviors as the C<iter> method.  The C<all>
method uses C<iter> internally to fetch all results.

=head3 C<test>

  if ( $rule->test( $path ) ) { ... }

Test a file path against a rule.  Used internally, but provided should
someone want to create their own, custom iteration routine.

=head2 Logic operations

C<Path::Class::Rule> provides three logic operations for adding rules to the
object.  Rules may be either a subroutine reference with specific semantics
(described below) or another C<Path::Class::Rule> object.

A rule subroutine gets a L<Path::Class> argument (which is also locally
aliased into the C<$_> global variable).  It must return one of three values:

=for :list
* A true value -- indicates the constraint is satisfied
* A false value -- indicates the constraint is not satisfied
* "0 but true" -- a special return value that signals that a directory
should not be searched recursively

The C<0 but true> value will shortcut logic (it is treated as "true" for
an "or" rule and "false" for an "and" rule.  It has no effect on files --
it is equivalent to returning a false value.

=head3 C<and>

=head3 C<or>

=head3 C<not>

=head1 RULE METHODS

=head2 File name rules

=head3 C<name>

=head2 File type rules

=head3 C<is_file>

=head3 C<is_dir>

=head2 File test rules

   Test | Method               Test |  Method
  ------|-------------        ------|----------------
    -r  |  readable             -R  |  r_readable
    -w  |  writeable            -W  |  r_writeable
    -w  |  writable             -W  |  r_writable
    -x  |  executable           -X  |  r_executable
    -o  |  owned                -O  |  r_owned
        |                           |
    -e  |  exists               -f  |  file
    -z  |  empty                -d  |  directory
    -s  |  nonempty             -l  |  symlink
        |                       -p  |  fifo
    -u  |  setuid               -S  |  socket
    -g  |  setgid               -b  |  block
    -k  |  sticky               -c  |  character
        |                       -t  |  tty
    -M  |  modified                 |
    -A  |  accessed             -T  |  ascii
    -C  |  changed              -B  |  binary

=head2 Stat test rules

  dev ino mode nlink uid gid rdev size atime mtime ctime blksize blocks

XXX document how these are used with Number::Compare

=head2 Special rules

=head3 C<skip_dirs>

  $rule->skip_dirs( @patterns );

The C<skip_dir> method

=head2 Negated rules

All rule methods have a negated form preceded by "not_".

  $rule->not_name("foo.*")

=head1 EXTENDING

One of the strengths of L<File::Find::Rule> is the many CPAN modules
that extend it.  C<Path::Class::Rule> provides the C<add_helper> method
to support this.

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

The C<add_helper> method takes two arguments, a C<name> for a rule method
and a closure-generating callback.

An inverted "not_*" method is generated automatically.

=head1 CAVEATS

Some features are still unimplemented.

=for :list
* Loop detection
* Taint mode support
* Error handling callback
* Depth limitations
* Assorted L<File::Find::Rule> helper (e.g. C<grep>)
* Extension class loading via C<import()>

=head1 SEE ALSO

There are many other file finding modules out there.  They all have various
features/deficiencies, depending on one's preferences and needs.  Here is an
(incomplete) list of alternatives, with some comparison commentary.

=head2 File::Find based modules

L<File::Find> is part of the Perl core.  It requires the user to write a
callback function to process each node of the search.  Callbacks must use
global variables to determine the current node.  It only supports depth-first
search (both pre- and post-order). It supports pre- and post-processing
callbacks; the former is required for sorting files to process in a directory.
L<File::Find::Closures> can be used to help create a callback for
L<File::Find>.

L<File::Find::Rule> is an object-oriented wrapper around L<File::Find>.  It
provides a number of helper functions and there are many more
C<File::Find::Rule::*> modules on CPAN with additional helpers.  It provides
an iterator interface, but precomputes all the results.

=head2 Path::Class based modules

L<Path::Class::Iterator> walks a directory structure with an iterator.  It is
implemented as L<Path::Class> subclasses, which adds a degree of extra
complexity. It takes a single callback to define "interesting" paths to return.
The callback gets a L<Path::Class::Iterator::File> or
L<Path::Class::Iterator::Dir> object for evaluation.

=head2 File::Next

L<File::Next> provides iterators for file, directories or "everything".  It
takes two callbacks, one to match files and one to decide which directories to
descend.  It does not allow control over breadth/depth order, though it does
provide means to sort files for processing within a directory. Like
L<File::Find>, it requires callbacks to use global varaibles.

=head2 Other modules

=for :list
* L<File::Find::Declare> - declarative helper rules; no iterator; Moose-based;
no control over ordering or following symlinks
* L<File::Find::Node> - no iterator; matching via callback; no control over
ordering

=cut

# vim: ts=2 sts=2 sw=2 et:
