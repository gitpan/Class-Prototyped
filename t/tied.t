use strict;
$^W++;
use Class::Prototyped qw(:NEW_MAIN);
use Test;

BEGIN {
	$|++;
  plan tests => 30;
}

my $p1 = new( a => 2, b => sub {'b'} );

ok( $p1->a, 2 );
ok( $p1->{a}, 2 );

ok( $p1->a(3), 3 );
ok( $p1->{a}, 3 );
ok( $p1->a, 3 );

ok( $p1->{a} = 4, 4 );
ok( $p1->a, 4 );
ok( $p1->{a}, 4 );

ok( $p1->b, 'b' );
ok( !(defined(eval { $p1->{b} })));
ok( $@ =~ /^attempt to access METHOD slot through tied hash object interface/ );

ok( !(defined(eval { $p1->{b} = 'c' })));
ok( $@ =~ /^attempt to access METHOD slot through tied hash object interface/ );

ok( !(defined(eval { $p1->{c} })));
ok( $@ =~ /^attempt to access non-existent slot through tied hash object interface/ );

ok( !(defined(eval { $p1->{c} = 'c' })));
ok( $@ =~ /^attempt to access non-existent slot through tied hash object interface/ );

ok( !(defined(eval { %{$p1} = (a => 2) })));
ok( $@ =~ /^attempt to call CLEAR on the hash interface of a Class::Prototyped object/ );

ok( join('|', keys %{$p1}), 'a');

$p1->reflect->addSlot('parent*', new( d => 5, e => sub {'e'}));
ok( join('|', keys %{$p1}), 'parent*|a');

ok( $p1->d, 5);
ok( !(defined(eval { $p1->{d} })));
ok( $@ =~ /^attempt to access non-existent slot through tied hash object interface/ );

ok( $p1->reflect->getSlot('parent*')->{d} = 7, 7);
ok( $p1->d, 7);

Class::Prototyped::import(qw(:TIED_INTERFACE autovivify));
my $p3 = $p1->clone;
ok( !(defined($p3->{d})));
ok( $p3->{d} = 4, 4 );
ok( $p3->d, 4 );

delete($p3->{d});
ok( $p3->d, 7);
# vim: ft=perl
