use Benchmark qw(cmpthese timeit);
use Data::Dumper;
use Tie::CPHash;

package My::Funky::Class;

sub foo {
	print "hi\n";
}

package main;

#print Data::Dumper->Dump([\%main::]);
my $package = 'My::Funky::Class';

my %cphash;
tie(%cphash, 'Tie::CPHash');

my $cphash = \$cphash;

$My::Funky::Class::mirrors = { $package => 'foo' };

mytimethese(500_000, {
	stringref => sub {
		my %foo = %{"$package\::"};
	},
	'bless_variable' => sub {
		bless {}, $package;
	},
	'bless_constant' => sub {
		bless {}, 'My::Funky::Class';
	},
	'tied' => sub {
		tied(%cphash);
	},
	hash_lookup => sub {
		$My::Funky::Class::mirrors->{$cphash} || 'foo';
		$My::Funky::Class::mirrors->{$package} || 'foo';
	},
	hash_lookup2 => sub {
		exists $My::Funky::Class::mirrors->{$cphash} ? $My::Funky::Class::mirrors->{$cphash} : 'foo';
		exists $My::Funky::Class::mirrors->{$package} ? $My::Funky::Class::mirrors->{$package} : 'foo';
	},
	ref_test => sub {
		ref($cphash) ? $My::Funky::Class::mirrors->{$cphash} : 'foo';
		ref($package) ? $My::Funky::Class::mirrors->{$package} : 'foo';
	},

});



sub get_package {
	my $string = shift;

	my $pkg = \%main::;	foreach (split(/::/, $string)) {$pkg = $pkg->{"$_\::"};}
	return $pkg;
}

sub mytimethese {
	my($iter, $codehash) = @_;

	foreach my $desc (sort keys %$codehash) {
		print "$desc:" . ' 'x(50-length($desc));
		my $time = timeit($iter, $codehash->{$desc});
		print sprintf('%8.2f usec', ($time->[1]+$time->[2])*1_000_000/$time->[5])."\n";
	}
}