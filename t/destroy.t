# Demonstrate wrapping
use strict;
$^W++;
use Class::Prototyped qw(:EZACCESS);
use Test;
BEGIN {
	$|++;
  plan tests => 2
}

my $record = '';

package MyClass;
@MyClass::ISA = qw(Class::Prototyped);

sub DESTROY {
  $record .= "You are in MyClass::DESTROY for " . ref($_[0]) . "\n";
}

package main;

my $name;
my $name2;

{
  my $foo = MyClass->new(
    'destroy!' => sub {
        $record .= "You are in the objects destroy.\n";
        $_[0]->super('destroy');
        $record .= "Just called super-destroy.\n";
      },
    );
  $name = ref($foo);
}

ok( $record, <<END);
You are in the objects destroy.
Just called super-destroy.
You are in MyClass::DESTROY for $name
END

$record = '';

{
  my $p1 = MyClass->new(
    'destroy!' => sub {
        $record .= "p1 before super\n";
        $_[0]->super('destroy');
        $record .= "p1 after super\n";
      },
    );
  $name = ref($p1);
  my $p2 = MyClass->new(
    'parent*' => $p1,
    'destroy!' => sub {
        $record .= "p2 before super\n";
        $_[0]->super('destroy');
        $record .= "p2 after super\n";
      },
    );
  $name2 = ref($p2);
}

# ??? What should this be?
# Getting:
#
# p2 before super
# p1 before super
# p1 after super
# You are in MyClass::DESTROY.
# p2 after super
# You are in MyClass::DESTROY.
#
ok( $record, <<END);
p2 before super
p1 before super
p1 after super
You are in MyClass::DESTROY for $name
p2 after super
You are in MyClass::DESTROY for $name2
END
# vim: ft=perl
