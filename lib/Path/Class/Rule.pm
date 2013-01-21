use 5.010; # re::regexp_pattern
use strict;
use warnings;

package Path::Class::Rule;
# ABSTRACT: File finder using Path::Class
# VERSION

# Register warnings category
use warnings::register;

# Dependencies
use re 'regexp_pattern';
use Carp;
use Data::Clone qw/data_clone/;
use List::Util qw/first/;
use Number::Compare 0.02;
use Path::Class::Dir 0.22 ();
use Scalar::Util qw/blessed/;
use Text::Glob qw/glob_to_regex/;
use Try::Tiny;

#--------------------------------------------------------------------------#
# constructors and meta methods
#--------------------------------------------------------------------------#

sub new {
  my $class = shift;
  return bless { rules => [ sub {1} ] }, ref $class || $class;
}

sub clone {
  my $self = shift;
  return data_clone($self);
}

sub add_helper {
  my ($class, $name, $coderef, $skip_negation) = @_;
  $class = ref $class || $class;
  if ( ! $class->can($name) ) {
    no strict 'refs'; ## no critic
    *$name = sub {
      my $self = shift;
      my $rule = $coderef->(@_);
      $self->and( $rule )
    };
    if ( ! $skip_negation ) {
      *{"not_$name"} = sub {
        my $self = shift;
        my $rule = $coderef->(@_);
        $self->not( $rule )
      };
    }
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
  depthfirst => 0,
  follow_symlinks => 1,
  loop_safe => ( $^O eq 'MSWin32' ? 0 : 1 ), # No inode #'s on Windows
  error_handler => sub { die sprintf("%s: %s", @_) },
);

sub iter {
  my $self = shift;
  my $args =  ref($_[0])  && !blessed($_[0])  ? shift
            : ref($_[-1]) && !blessed($_[-1]) ? pop : {};
  my $opts = { %defaults, %$args };
  my @queue = map { { path => Path::Class::Dir->new($_), depth => 0 } } @_ ? @_ : '.';
  my $stash = {};
  my %seen;

  return sub {
    LOOP: {
      my $task = shift @queue
        or return;
      my ($item, $depth) = @{$task}{qw/path depth/};
      return $$item if ref $item eq 'REF'; # deferred for postorder
      if ( ! $opts->{follow_symlinks} ) {
        redo LOOP if -l $item;
      }
      local $_ = $item;
      $stash->{_depth} = $depth;
      my $interest =
        try   { $self->test($item, $stash) }
        catch { $opts->{error_handler}->($item, $_) };
      my $prune = $interest && ! (0+$interest); # capture "0 but true"
      $interest += 0;                           # then ignore "but true"
      my $unique_id = $self->_unique_id($item, $opts);
      if ($item->is_dir && ! $seen{$unique_id}++ && ! $prune) {
        if ( ! -r $item ) {
            warnings::warnif("Directory '$item' is not readable. Skipping it");
        }
        elsif ( $opts->{depthfirst} ) {
          my @next = $self->_taskify($depth+1, $item->children);
          # for postorder, requeue as reference to signal it can be returned
          # without being retested
          push @next, { path => \$item, depth => $depth}
            if $interest && $opts->{depthfirst} > 0;
          unshift @queue, @next;
          redo LOOP if $opts->{depthfirst} > 0;
        }
        else {
          push @queue, $self->_taskify($depth+1, $item->children);
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

sub skip {
  my $self = shift;
  my @rules = $self->_rulify("not", @_);
  my $obj = $self->new->or(@rules);
  my $coderef = sub {
    my $item = shift;
    my $result = $obj->test($item);
    return $result ? "0 but true" : "1";
  };
  return $self->and( $coderef );
}

sub test {
  my ($self, $item, $stash) = @_;
  my $result;
  for my $rule ( @{$self->{rules}} ) {
    $result = $rule->($item, $stash) || 0;
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

sub _taskify {
  my ($self, $depth, @paths) = @_;
  return map { {path => $_, depth => $depth} } sort @paths;
}

sub _unique_id {
  my ($self, $item, $opts) = @_;
  my $unique_id;
  if ($opts->{loop_safe}) {
    my $st = eval { $item->stat || $item->lstat };
    if ( $st ) {
      $unique_id = join(",", $st->dev, $st->ino);
    }
    else {
      my $type = $item->is_dir ? 'directory' : 'file';
      warnings::warnif("Could not stat $type '$item'");
      $unique_id = $item;
    }
  }
  else {
    $unique_id = $item;
  }
  return $unique_id;
}
#--------------------------------------------------------------------------#
# built-in helpers
#--------------------------------------------------------------------------#

sub _regexify {
  my ($re, $add) = @_;
  $add ||= '';
  my $new = ref($re) eq 'Regexp' ? $re : glob_to_regex($re);
  my ($pattern, $flags) = regexp_pattern($new);
  my $new_flags = $add ? _reflag($flags, $add) : "";
  return qr/$new_flags$pattern/;
}

sub _reflag {
  my ($orig, $add) = @_;
  $orig ||= "";

  if ( $] >= 5.014 ) {
    return "(?^$orig$add)";
  }
  else {
    my ($pos, $neg) = split /-/, $orig;
    $pos ||= "";
    $neg ||= "";
    $neg =~ s/i//;
    $neg = "-$neg" if length $neg;
    return "(?$add$pos$neg)";
  }
}

# "simple" helpers take no arguments
my %simple_helpers = (
  # use Path::Class::is_dir instead of extra -d call
  ( map { $_ => sub { $_->is_dir } } qw/dir directory/ ),
  dangling => sub { -l $_ && ! $_->stat },
);

while ( my ($k,$v) = each %simple_helpers ) {
  __PACKAGE__->add_helper( $k, sub { return $v } );
}

# "complex" helpers take arguments
my %complex_helpers = (
  name => sub {
    Carp::croak("No patterns provided to 'name'") unless @_;
    my @patterns = map { _regexify($_) } @_;
    return sub {
      my $f = shift;
      my $name = $f->basename;
      return (first { $name =~ $_} @patterns ) ? 1 : 0;
    }
  },
  iname => sub {
    Carp::croak("No patterns provided to 'iname'") unless @_;
    my @patterns = map { _regexify($_, "i") } @_;
    return sub {
      my $f = shift;
      my $name = $f->basename;
      return (first { $name =~ m{$_}i } @patterns ) ? 1 : 0;
    }
  },
  min_depth => sub {
    Carp::croak("No depth argument given to 'min_depth'") unless @_;
    my $min_depth = 0 + shift; # if this warns, do here and not on every file
    return sub {
      my ($f, $stash) = @_;
      return $stash->{_depth} >= $min_depth;
    }
  },
  max_depth => sub {
    Carp::croak("No depth argument given to 'max_depth'") unless @_;
    my $max_depth = 0 + shift; # if this warns, do here and not on every file
    return sub {
      my ($f, $stash) = @_;
      return $stash->{_depth} <= $max_depth ? 1 : "0 but true"; # prune
    }
  },
  shebang => sub {
    Carp::croak("No patterns provided to 'shebang'") unless @_;
    my @patterns = map { _regexify($_) } @_;
    return sub {
      my $f = shift;
      return unless ! $f->is_dir;
      my $fh = $f->open;
      my $shebang = <$fh>;
      return unless defined $shebang;
      return (first { $shebang =~ $_} @patterns ) ? 1 : 0;
    };
  },
);

while ( my ($k,$v) = each %complex_helpers ) {
  __PACKAGE__->add_helper( $k, $v );
}

# skip_dirs
__PACKAGE__->add_helper(
  skip_dirs => sub {
    Carp::croak("No patterns provided to 'skip_dirs'") unless @_;
    my $name_check = Path::Class::Rule->new->name(@_);
    return sub {
      my $f = shift;
      return "0 but true" if $f->is_dir && $name_check->test($f);
      return 1; # otherwise, like a null rule
    }
  } => 1 # don't create not_skip_dirs
);

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

# VCS rules adapted from File::Find::Rule::VCS
my %vcs_rules = (
  skip_cvs => sub {
    return Path::Class::Rule->new->skip_dirs('CVS')->not_name(qr/\.\#$/);
  },
  skip_rcs => sub {
    return Path::Class::Rule->new->skip_dirs('RCS')->not_name(qr/,v$/);
  },
  skip_git => sub {
    return Path::Class::Rule->new->skip_dirs('.git');
  },
  skip_svn => sub {
    return Path::Class::Rule->new->skip_dirs(
        ($^O eq 'MSWin32') ? ('.svn', '_svn') : ('.svn')
    );
  },
  skip_bzr => sub {
    return Path::Class::Rule->new->skip_dirs('.bzr');
  },
  skip_hg => sub {
    return Path::Class::Rule->new->skip_dirs('.hg');
  },
  skip_vcs => sub {
    return Path::Class::Rule->new
      ->skip_dirs(qw/.git .bzr .hg CVS RCS/)
      ->skip_svn
      ->not_name(qr/\.\#$/, qr/,v$/);
  },
);

while ( my ($name, $coderef) = each %vcs_rules ) {
  __PACKAGE__->add_helper( $name, $coderef, 1 ); # don't create not_*
}


# perl rules adapted from File::Find::Rule::Perl
my %perl_rules = (
  perl_module     => sub { return Path::Class::Rule->new->file->name('*.pm') },
  perl_pod        => sub { return Path::Class::Rule->new->file->name('*.pod') },
  perl_test       => sub { return Path::Class::Rule->new->file->name('*.t') },
  perl_installer  => sub {
    return Path::Class::Rule->new->file->name('Makefile.PL', 'Build.PL')
  },
  perl_script     => sub {
    return Path::Class::Rule->new->file->or(
      Path::Class::Rule->new->name('*.pl'),
      Path::Class::Rule->new->shebang(qr/#!.*\bperl\b/),
    );
  },
  perl_file       => sub {
    return Path::Class::Rule->new->or(
      Path::Class::Rule->new->perl_module,
      Path::Class::Rule->new->perl_pod,
      Path::Class::Rule->new->perl_test,
      Path::Class::Rule->new->perl_installer,
      Path::Class::Rule->new->perl_script,
    );
  },
);

while ( my ($name, $coderef) = each %perl_rules ) {
  __PACKAGE__->add_helper( $name, $coderef );
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

Here is a summary of features for comparison to other file finding modules:

=for :list
* provides many "helper" methods for specifying rules
* offers (lazy) iterator and flattened list interfaces
* returns L<Path::Class> objects
* custom rules implemented with callbacks
* breadth-first (default) or pre- or post-order depth-first searching
* follows symlinks (by default, but can be disabled)
* directories visited only once (no infinite loops)
* doesn't chdir during operation
* provides an API for extensions

=head1 USAGE

=head2 Constructors

=head3 C<new>

  my $rule = Path::Class::Rule->new;

Creates a new rule object that matches any file or directory.  It takes
no arguments. For convenience, it may also be called on an object, in which
case it still returns a new object that matches any file or directory.

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
* C<error_handler> -- Catches errors during execution of rule tests. Default handler dies with the filename and error.
* C<follow_symlinks> -- Follow directory symlinks when true. Default is 1.
* C<loop_safe> -- Prevents visiting the same directory more than once when true.  Default is 1.

Filesystem loops might exist from either hard or soft links.  The C<loop_safe>
option prevents infinite loops, but adds some overhead by making C<stat> calls.
Because directories are visited only once when C<loop_safe> is true, matches
could come from a symlinked directory before the real directory depending on
the search order.  To get only the real files, turn off C<follow_symlinks>.
Turning C<loop_safe> off and leaving C<follow_symlinks> on avoids C<stat> calls
and will be fastest, but with the risk of an infinite loop and repeated files.
The default is slow, but safe.

The C<error_handler> parameter must be a subroutine reference.  It will be
called when a rule test throws an exception.  The first argument will be
the L<Path::Class> object being inspected and the second argument will be
the exception.

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
(described below in L</EXTENDING>) or another C<Path::Class::Rule> object.

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

=head3 C<skip>

  $rule->skip(
    $rule->new->dir->not_writeable,
    $rule->new->dir->name("foo"),
  );

Takes one or more alternatives and will prune a directory if any of the
criteria match.  For files, it is equivalent to
C<< $rule->not($rule->or(@rules)) >>.  Returns the object to allow method
chaining.

This method should be called as early as possible in the rule chain.
See L</skip_dirs> below for further explanation and an example.

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

=head3 C<iname>

  $rule->iname( "foo.txt" );
  $rule->iname( qr/foo/, "bar.*");

The C<iname> method is just like the C<name> method, but matches
case-insensitively.

=head3 C<skip_dirs>

  $rule->skip_dirs( @patterns );

The C<skip_dirs> method skips directories that match one or more patterns.
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

=head2 Depth rules

  $rule->min_depth(3);
  $rule->max_depth(5);

The C<min_depth> and C<max_depth> rule methods take a single argument
and limit the paths returned to a minimum or maximum depth (respectively)
from the starting search directory.

=head2 Perl file rules

  # All perl rules
  $rule->perl_file;

  # Individual perl file rules
  $rule->perl_module;     # .pm files
  $rule->perl_pod;        # .pod files 
  $rule->perl_test;       # .t files
  $rule->perl_installer;  # Makefile.PL or Build.PL
  $rule->perl_script;     # .pl or 'perl' in the shebang

These rule methods match file names (or a shebang line) that are typical
of Perl distribution files.

=head2 Version control file rules

  # Skip all known VCS files
  $rule->skip_vcs;

  # Skip individual VCS files
  $rule->skip_cvs;
  $rule->skip_rcs;
  $rule->skip_svn;
  $rule->skip_git;
  $rule->skip_bzr;
  $rule->skip_hg;

Skips files and/or prunes directories related to a version control system.
Just like C<skip_dirs>, these rules should be specified early to get the
correct behavior.

=head2 Other rules

=head3 C<dangling>

  $rule->symlink->dangling;
  $rule->not_dangling;

The C<dangling> rule method matches dangling symlinks.  Use it or its inverse
to control how dangling symlinks should be treated.  Note that a dangling
symlink will be returned by the iterator as a L<Path::Class::File> object.

=head3 C<shebang>

  $rule->shebang(qr/#!.*\bperl\b/);

The C<shebang> rule takes a list of regular expressions or glob patterns and
checks them against the first line of a file.

=head2 Negated rules

Most rule methods have a negated form preceded by "not_".

  $rule->not_name("foo.*")

Because this happens automatically, it includes somewhat silly ones like
C<not_nonempty> (which is thus a less efficient way of saying C<empty>).

Rules that skip directories or version control files do not have a negated
version.

=head1 EXTENDING

=head2 Custom rule subroutines

Rules are implemented as (usually anonymous) subroutines callbacks that return
a value indicating whether or not the rule matches.  These callbacks are called
with two arguments.  The first argument is a L<Path::Class> object, which is
also locally aliased as the C<$_> global variable for convenience in simple
tests.

  $rule->and( sub { -r -w -x $_ } ); # tests $_

The second argument is a hash reference that can be used to maintain state.
Keys beginning with an underscore are B<reserved> for C<Path::Class::Rule>
to provide additional data about the search in progress.
For example, the C<_depth> key is used to support minimum and maximum
depth checks.

The custom rule subroutine must return one of three values:

=for :list
* A true value -- indicates the constraint is satisfied
* A false value -- indicates the constraint is not satisfied
* "0 but true" -- a special return value that signals that a directory should not be searched recursively

The C<0 but true> value will shortcut logic (it is treated as "true" for an
"or" rule and "false" for an "and" rule).  For a directory, it ensures that the
directory will not be returned from the iterator and that its children will not
be evaluated either.  It has no effect on files -- it is equivalent to
returning a false value.

For example, this is equivalent to the "max_depth" rule method with
a depth of 3:

  $rule->and(
    sub {
      my ($path, $stash) = @_;
      return $stash->{_depth} <= 3 ? 1 : "0 but true";
    }
  );

Files of depth 4 will not be returned by the iterator; directories of depth
4 will not be returned and will not be searched.

Generally, if you want to do directory pruning, you are encouraged to use the
L</skip> method instead of writing your own logic using C<0 but true>.

=head2 Extension modules and custom rule methods

One of the strengths of L<File::Find::Rule> is the many CPAN modules
that extend it.  C<Path::Class::Rule> provides the C<add_helper> method
to provide a similar mechanism for extensions.

The C<add_helper> class method takes three arguments, a C<name> for the rule
method, a closure-generating callback, and a flag for not generating a negated
form of the rule.  Unless the flag is true, an inverted "not_*" method is
generated automatically.  Extension classes should call this as a class method
to install new rule methods.  For example, this adds a "foo" method that checks
if the filename is "foo":

  package Path::Class::Rule::Foo;

  use Path::Class::Rule;

  Path::Class::Rule->add_helper(
    foo => sub {
      my @args = @_; # do this to customize closure with arguments
      return sub {
        my ($item) = shift;
        return if $item->is_dir;
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

=head1 LEXICAL WARNINGS

If you run with lexical warnings enabled, C<Path::Class::Rule> will issue
warnings in certain circumstances (such as a read-only directory that must be
skipped).  To disable these categories, put the following statement at the
correct scope:

  no warnings 'Path::Class::Rule';

=head1 CAVEATS

This is an early release for community feedback and contribution.
Some features are still unimplemented:

=for :list
* Untainting options
* Some L<File::Find::Rule> helpers (e.g. C<grep>)
* Extension class loading via C<import()>

Filetest operators and stat rules are subject to the usual portability
considerations.  See L<perlport> for details.

Performance suffers somewhat from all of the abstraction layers
of L<Path::Class> and L<File::Spec>.  Hopefully, convenience
makes up for that.

=head1 SEE ALSO

There are many other file finding modules out there.  They all have various
features/deficiencies, depending on your preferences and needs.  Here is an
(incomplete) list of alternatives, with some comparison commentary.

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

L<File::Next> provides iterators for file, directories or "everything".  It
takes two callbacks, one to match files and one to decide which directories to
descend.  It does not allow control over breadth/depth order, though it does
provide means to sort files for processing within a directory. Like
L<File::Find>, it requires callbacks to use global variables.

L<Path::Class::Iterator> walks a directory structure with an iterator.  It is
implemented as L<Path::Class> subclasses, which adds a degree of extra
complexity. It takes a single callback to define "interesting" paths to return.
The callback gets a L<Path::Class::Iterator::File> or
L<Path::Class::Iterator::Dir> object for evaluation.

L<File::Find::Object> and companion L<File::Find::Object::Rule> are like
File::Find and File::Find::Rule, but without File::Find inside.  They use an
iterator that does not precompute results. They can return
L<File::Find::Object::Result> objects, which give a subset of the utility
of Path::Class objects.  L<File::Find::Object::Rule> appears to be a literal
translation of L<File::Find::Rule>, including oddities like making C<-M> into a
boolean.

L<File::chdir::WalkDir> recursively descends a tree, calling a callback on each
file.  No iterator.  Supports exclusion patterns.  Depth-first post-order by
default, but offers pre-order option. Does not process symlinks.

L<File::Find::Iterator> is based on iterator patterns in Higher Order Perl.  It
allows a filtering callback. Symlinks are followed automatically without
infinite loop protection. No control over order. It offers a "state file"
option for resuming interrupted work.

L<File::Find::Declare> has declarative helper rules, no iterator, is
Moose-based and offers no control over ordering or following symlinks.

L<File::Find::Node> has no iterator, does matching via callback and offers
no control over ordering.

L<File::Set> builds up a set of files to operate on from a list of directories
to include or exclude, with control over recursion.  A callback is applied to
each file (or directory) in the set.  There is no iterator.  There is no
control over ordering.  Symlinks are not followed.  It has several extra
features for checksumming the set and creating tarballs with F</bin/tar>.

=cut

# vim: ts=2 sts=2 sw=2 et:
