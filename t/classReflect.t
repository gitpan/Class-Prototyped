use strict;
$^W++;
use Class::Prototyped qw(:REFLECT);
use Test;

BEGIN {
	$|++;
	plan tests => 11;
}

package A;
sub a {'A.a'}

package main;

my $p = Class::Prototyped->new();
my $pm = $p->reflect;

my $a = A->reflect;

my @slotNames = $a->slotNames;
ok( @slotNames, 1 );
ok( $slotNames[0], 'a' );

my %slots = $a->getSlots;
ok( scalar keys %slots, 1 );
ok( defined( $slots{a} ) );
ok( $a->getSlot('a') == UNIVERSAL::can( 'A', 'a' ) );

$a->addSlots( 'bb' => sub {'A.bb'} );

@slotNames = $a->slotNames;
ok( @slotNames, 2 );

%slots = $a->getSlots;
ok( scalar keys %slots, 2 );
ok( defined( $slots{bb} ) );
ok( $a->getSlot('bb') == A->can('bb') );

ok( ref( $a->object ), 'A' );
ok( defined( UNIVERSAL::can( 'A', 'bb' ) ) );

# vim: ft=perl
