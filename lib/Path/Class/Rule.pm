use 5.008001;
use strict;
use warnings;

package Path::Class::Rule;
# ABSTRACT: File finder using Path::Class
# VERSION

# Dependencies
use namespace::autoclean;
use Carp;
use List::Util qw/first/;
use Number::Compare 0.02;
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
    no strict 'refs'; ## no critic
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
  else {
    Carp::carp(
      "Can't add rule '$name' because it conflicts with an existing method"
    );
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

# "simple" helpers take no arguments
my %simple_helpers = (
  # use Path::Class::is_dir instead of extra -d call
  map { $_ => sub { $_->is_dir } } qw/dir directory/,
);

while ( my ($k,$v) = each %simple_helpers ) {
  __PACKAGE__->add_helper( $k, sub { return $v } );
}

# "complex" helpers take arguments
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

# X_tests adapted from File::Find::Rule
my %X_tests = (
    -r  =>  readable           =>  -R  =>  r_readable      =>
    -w  =>  writeable          =>  -W  =>  r_writeable     =>
    -w  =>  writable           =>  -W  =>  r_writable      =>
    -x  =>  executable         =>  -X  =>  r_executable    =>
    -o  =>  owned              =>  -O  =>  r_owned         =>

    -e  =>  exists             =>  -f  =>  file            =>
    -z  =>  empty              => # -d implemented above using is_dir
    -s  =>  nonempty           =>  -l  =>  symlink         =>
                               =>  -p  =>  fifo            =>
    -u  =>  setuid             =>  -S  =>  socket          =>
    -g  =>  setgid             =>  -b  =>  block           =>
    -k  =>  sticky             =>  -c  =>  character       =>
                               =>  -t  =>  tty             =>
    -T  =>  ascii              =>
    -B  =>  binary             =>
);

while ( my ($op,$name) = each %X_tests ) {
  my $coderef = eval "sub { $op \$_ }"; ## no critic
  __PACKAGE__->add_helper( $name, sub { return $coderef } );
}

my %time_tests = (
    -A  => accessed =>
    -M  => modified =>
    -C  => changed  =>
);

while ( my ($op,$name) = each %time_tests ) {
  my $filetest = eval "sub { $op \$_ }"; ## no critic
  my $coderef = sub {
    Carp::croak("The '$name' test requires a single argument") unless @_ == 1;
    my $comparator = Number::Compare->new(shift);
    return sub { return $comparator->($filetest->()) };
  };
  __PACKAGE__->add_helper( $name, $coderef );
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

=head1 SYNOPSIS

  use Path::Class::Rule;

  my $rule = Path::Class::Rule->new; # match anything
  $rule->file->size(">10k");      # add/chain rules

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
no arguments. For convenience, it may also be called on an object, in which
case it still returns a new object hat matches any file or directory.

=head3 C<clone>

  my $common      = Path::Class::Rule->new->file->not_empty;
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

Creates a subroutine reference iterator that returns a single L<Path::Class>
object when dereferenced.  This iterator is "lazy" -- results are not
pre-computed.

It takes as arguments a list of directories to search and an optional hash
reference of control options.  If no search directories are provided, the
current directory is used (C<".">).  Valid options include:

=for :list
* C<depthfirst> -- Controls order of results.  Valid values are "1" (post-order, depth-first search), "0" (breadth-first search) or "-1" (pre-order, depth-first search). Default is 0.
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
someone want to create their own, custom iteration algorithm.

=head2 Logic operations

C<Path::Class::Rule> provides three logic operations for adding rules to the
object.  Rules may be either a subroutine reference with specific semantics
(described below) or another C<Path::Class::Rule> object.

A rule subroutine gets a L<Path::Class> argument (which is also locally
aliased into the C<$_> global variable).  It must return one of three values:

=for :list
* A true value -- indicates the constraint is satisfied
* A false value -- indicates the constraint is not satisfied
* "0 but true" -- a special return value that signals that a directory should not be searched recursively

The C<0 but true> value will shortcut logic (it is treated as "true" for an
"or" rule and "false" for an "and" rule).  For a directory, it ensures that the
directory will not be returned from the iterator and that its children will not
be evaluated either.  It has no effect on files -- it is equivalent to
returning a false value.

=head3 C<and>

  $rule->and( sub { -r -w -x $_ } ); # stacked filetest example
  $rule->and( @more_rules );

Adds one or more constraints to the current rule. E.g. "old rule AND
new1 AND new2 AND ...".  Returns the object to allow method chaining.

=head3 C<or>

  $rule->or(
    $rule->new->name("foo*"),
    $rule->new->name("bar*"),
    sub { -r -w -x $_ },
  );

Takes one or more alternatives and adds them as a constraint to the current
rule. E.g. "old rule AND ( new1 OR new2 OR ... )".  Returns the object to allow
method chaining.

=head3 C<not>

  $rule->not( sub { -r -w -x $_ } );

Takes one or more alternatives and adds them as a negative constraint to the
current rule. E.g. "old rule AND NOT ( new1 AND new2 AND ...)".  Returns the
object to allow method chaining.

=head1 RULE METHODS

Rule methods are helpers that add constraints.  Internally, they generate a
closure to accomplish the desired logic and add it to the rule object with the
C<and> method.  Rule methods return the object to allow for method chaining.

=head2 File name rules

=head3 C<name>

  $rule->name( "foo.txt" );
  $rule->name( qr/foo/, "bar.*");

The C<name> method takes one or more patterns and creates a rule that is true
if any of the patterns match the B<basename> of the file or directory path.
Patterns may be regular expressions or glob expressions (or literal names).

=head3 C<skip_dirs>

  $rule->skip_dirs( @patterns );

The C<skip_dirs> method skips directories that match or or more patterns.
Patterns may be regular expressions or globs (just like C<name>).  Directories
that match will not be returned from the iterator and will be excluded from
further search.

B<Note:> this rule should be specified early so that it has a chance to
operate before a logical shortcut.  E.g.

  $rule->skip_dirs(".git")->file; # OK
  $rule->file->skip_dirs(".git"); # Won't work

In the latter case, when a ".git" directory is seen, the C<file> rule
shortcuts the rule before the C<skip_dirs> rule has a chance to act.

=head2 File test rules

Most of the C<-X> style filetest are available as boolean rules.  The table
below maps the filetest to its corresponding method name.

   Test | Method               Test |  Method
  ------|-------------        ------|----------------
    -r  |  readable             -R  |  r_readable
    -w  |  writeable            -W  |  r_writeable
    -w  |  writable             -W  |  r_writable
    -x  |  executable           -X  |  r_executable
    -o  |  owned                -O  |  r_owned
        |                           |
    -e  |  exists               -f  |  file
    -z  |  empty                -d  |  directory, dir
    -s  |  nonempty             -l  |  symlink
        |                       -p  |  fifo
    -u  |  setuid               -S  |  socket
    -g  |  setgid               -b  |  block
    -k  |  sticky               -c  |  character
        |                       -t  |  tty
    -T  |  ascii
    -B  |  binary

For example:

  $rule->file->nonempty; # -f -s $file

The -X operators for timestamps take a single argument in a form that
L<Number::Compare> can interpret.

   Test | Method
  ------|-------------
    -A  |  accessed
    -M  |  modified
    -C  |  changed

For example:

  $rule->modified(">1"); # -M $file > 1

=head2 Stat test rules

All of the C<stat> elements have a method that takes a single argument in
a form understood by L<Number::Compare>.

  stat()  |  Method
 --------------------
       0  |  dev
       1  |  ino
       2  |  mode
       3  |  nlink
       4  |  uid
       5  |  gid
       6  |  rdev
       7  |  size
       8  |  atime
       9  |  mtime
      10  |  ctime
      11  |  blksize
      12  |  blocks

For example:

  $rule->size(">10K")

=head2 Negated rules

All rule methods have a negated form preceded by "not_".

  $rule->not_name("foo.*")

Because this happens automatically, it includes somewhat silly ones like
C<not_nonempty> (which is thus a less efficient way of saying C<empty>).

=head1 EXTENDING

One of the strengths of L<File::Find::Rule> is the many CPAN modules
that extend it.  C<Path::Class::Rule> provides the C<add_helper> method
to provide a similar mechanism for extensions.

=head2 C<add_helper>

The C<add_helper> method takes two arguments, a C<name> for the rule method and
a closure-generating callback.  An inverted "not_*" method is generated
automatically.  Extension classes should call this as a class method to
install new rule methods.  For example, this adds a "foo" method that checks
if the filename is "foo":

  package Path::Class::Rule::Foo;

  use Path::Class::Rule;

  Path::Class::Rule->add_helper(
    foo => sub {
      my @args = @_; # do this to customize closure with arguments
      return sub {
        my ($item) = shift;
        return $item->basename =~ /^foo$/;
      }
    }
  );

  1;

This allows the following rule methods:

  $rule->foo;
  $fule->not_foo;

The C<add_helper> method will warn and ignore a helper with the same name as
an existing method.

=head1 CAVEATS

This is an early release for community feedback and contribution.  The
API may still change.  Some features are still unimplemented:

=for :list
* True loop detection
* Taint mode support
* Error handling callback
* Depth limitations
* Assorted L<File::Find::Rule> helpers (e.g. C<grep>)
* Extension class loading via C<import()>

Test coverage is still poor.

Filetest operators and stat rules are subject to the usual portability
considerations.  See L<perlport> for details.

=head1 SEE ALSO

There are many other file finding modules out there.  They all have various
features/deficiencies, depending on one's preferences and needs.  Here is an
(incomplete) list of alternatives, with some comparison commentary.

=head2 File::Find

L<File::Find> is part of the Perl core.  It requires the user to write a
callback function to process each node of the search.  Callbacks must use
global variables to determine the current node.  It only supports depth-first
search (both pre- and post-order). It supports pre- and post-processing
callbacks; the former is required for sorting files to process in a directory.
L<File::Find::Closures> can be used to help create a callback for
L<File::Find>.

=head2 File::Find::Rule

L<File::Find::Rule> is an object-oriented wrapper around L<File::Find>.  It
provides a number of helper functions and there are many more
C<File::Find::Rule::*> modules on CPAN with additional helpers.  It provides
an iterator interface, but precomputes all the results.

=head2 File::Next

L<File::Next> provides iterators for file, directories or "everything".  It
takes two callbacks, one to match files and one to decide which directories to
descend.  It does not allow control over breadth/depth order, though it does
provide means to sort files for processing within a directory. Like
L<File::Find>, it requires callbacks to use global varaibles.

=head2 Path::Class::Iterator

L<Path::Class::Iterator> walks a directory structure with an iterator.  It is
implemented as L<Path::Class> subclasses, which adds a degree of extra
complexity. It takes a single callback to define "interesting" paths to return.
The callback gets a L<Path::Class::Iterator::File> or
L<Path::Class::Iterator::Dir> object for evaluation.

=head2 File::Find::Declare

L<File::Find::Declare> has declarative helper rules, no iterator, is
Moose-based and offers no control over ordering or following symlinks.

=head2 File::Find::Node

L<File::Find::Node> has no iterator, does matching via callback and offers
no control over ordering.

=cut

# vim: ts=2 sts=2 sw=2 et:
