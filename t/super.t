# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'
# To run by itself, you can go
# perl -Mblib super.t
use strict;
$^W++;
use Class::Prototyped qw(:REFLECT :EZACCESS :OVERLOAD);
use Test;
BEGIN {
  $|++;
  plan tests => 24
}

my $p1 = Class::Prototyped->new( s1 => sub {'p1.s1'} );

my $p2 = Class::Prototyped->new(
  '*'   => $p1,
  s1    => sub {'p2.s1'},
  's2!' => sub { shift->reflect->super('s1') },
);

my $p2a = $p2->clone();

my $p3 = Class::Prototyped->new(
  '*'   => $p2,
  s1    => sub {'p3.s1'},
  's2!' => sub { shift->super('s1') },
  's3!' => sub { shift->super('s2') },
  's4!' => sub { join('+', $_[0]->s2, $_[0]->super('s1'), $_[0]->super('s2') ) },
  's5!' => sub { join('+', $_[0]->s2, $_[0]->super('s2'), $_[0]->super('s1') ) },
  's6'  => sub { join('+', map {$_[0]->$_()} map {"s$_"} (1..5) ) },
);

my $p3a = $p3->clone();

ok( $p1->s1,  'p1.s1' );
ok( $p2->s1,  'p2.s1' );
ok( $p2->s2,  'p1.s1' );
ok( $p2a->s1, 'p2.s1' );
ok( $p2a->s2, 'p1.s1' );
ok( $p3->s1,  'p3.s1' );
ok( $p3->s2,  'p2.s1' );
ok( $p3->s3,  'p1.s1' );
ok( $p3->s4,  'p2.s1+p2.s1+p1.s1' );
ok( $p3->s5,  'p2.s1+p1.s1+p2.s1' );
ok( $p3->s6,  'p3.s1+p2.s1+p1.s1+p2.s1+p2.s1+p1.s1+p2.s1+p1.s1+p2.s1' );
ok( $p3a->s1, 'p3.s1' );
ok( $p3a->s2, 'p2.s1' );
ok( $p3a->s3, 'p1.s1' );
ok( $p3a->s4, 'p2.s1+p2.s1+p1.s1' );
ok( $p3a->s5, 'p2.s1+p1.s1+p2.s1' );
ok( $p3a->s6, 'p3.s1+p2.s1+p1.s1+p2.s1+p2.s1+p1.s1+p2.s1+p1.s1+p2.s1' );


package MyClass;
@MyClass::ISA = qw(Class::Prototyped);

MyClass->addSlots(
  'new!' => sub {
    my $class = shift;
    my $self = $class->super('new');
    $self->reflect->addSlots(
      value => $self->value()*2,
      @_
    );
    return $self;
  },
  value => 2,
);

package main;

my $p4 = MyClass->new();
ok( $p4->value, 4 );

MyClass->value(3);

my $p5 = MyClass->new();
ok( $p4->value, 4 );
ok( $p5->value, 6 );

Class::Prototyped->newPackage('MyClass::Sub',
  '*' => 'MyClass',
  'new!' => sub {
    my $class = shift;
    my $self = $class->super('new', @_);
    $self->value($self->value()+5);
    return $self;
  },
);

my $p6 = MyClass::Sub->new();
ok( $p4->value, 4 );
ok( $p5->value, 6 );
ok( $p6->value, 11);

my $p7 = MyClass::Sub->new(value => 20);
ok( $p7->value, 25);

# vim: ft=perl
