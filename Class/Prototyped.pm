# Class::Prototyped - Fast prototype-based OO programming in Perl
# $Revision: 1.37 $

package Class::Prototyped;
use strict;
use Carp();

$Class::Prototyped::VERSION = '0.90';

sub import {
  while ( my $symbol = shift ) {
    if ( $symbol eq ':OVERLOAD' ) {
      unless ( scalar keys %Class::Prototyped::overloadable_symbols ) {
        eval "use overload";
        @Class::Prototyped::overloadable_symbols{ map {split}
          values %overload::ops } = undef;
      }
    }
    elsif ( $symbol eq ':REFLECT' ) {
      *UNIVERSAL::reflect =
        sub { Class::Prototyped::Mirror->new( $_[0] ) };
    }
    elsif ( $symbol eq ':EZACCESS' ) {
      no strict 'refs';

      foreach my $call (
        qw(addSlot addSlots deleteSlot deleteSlots getSlot getSlots super)
        ) {
        *{$call} = sub {
          # unshift ( @_, shift->reflect );
          # goto &{ UNIVERSAL::can( $_[0], $call ) };
          my $obj = shift->reflect;
          UNIVERSAL::can( $obj, $call )->( $obj, @_ );
        };
      }
    }
    elsif ( $symbol eq ':SUPER_FAST' ) {
      *Class::Prototyped::Mirror::super =
        \&Class::Prototyped::Mirror::super_fast;
    }
    elsif ( $symbol eq ':NEW_MAIN' ) {
      *main::new = sub { Class::Prototyped->new(@_) };
    }
    elsif ( $symbol eq ':TIED_INTERFACE' ) {
      my $value   = shift;
      my $package = {
        'default'    => 'Class::Prototyped::Tied::Default',
        'autovivify' => 'Class::Prototyped::Tied::AutoVivify',
      }->{$value} || $value;

      if ( $package eq $value && scalar( keys %{"$package\::"} ) == 0 ) {
        eval "use $package";
        Carp::croak
"attempt to import package for :TIED_INTERFACE failed:\n$package"
          if $@;
      }
      local $^W = 0;
      *Class::Prototyped::Mirror::DEFAULT_TIED_INTERFACE = sub {$package};
    }
  }
}

# Constructor. Pass in field definitions.
sub new {
  my $self = {};
  tie %$self, &Class::Prototyped::Mirror::DEFAULT_TIED_INTERFACE();
  my $package =
    &Class::Prototyped::Mirror::PREFIX
    . substr( "$self", 7, -1 );    # HASH($package)
  my $class = shift;
  Carp::croak("odd number of arguments to new\n") if scalar(@_) % 2;
  $class->newPackage( $package, $self, @_ );
}

sub newPackage {
  my $class   = shift;
  my $package = shift;

  my ( $self, $tied );
  {
    no strict 'refs';

    if ( substr( $package, 0, &Class::Prototyped::Mirror::PREFIX_LENGTH ) ne
      &Class::Prototyped::Mirror::PREFIX )
    {
      if ( scalar( keys %{"$package\::"} ) ) {
        Carp::croak(
          "attempt to use newPackage with already existing package\n"
          . "package: $package" );
      }
      my %self;
      tie %self, &Class::Prototyped::Mirror::DEFAULT_TIED_INTERFACE();
      $tied = tied %self;
      $Class::Prototyped::Mirror::objects{$package} = $self = \%self;
    }
    else {
      $self = shift;
      $tied = tied %$self;
      *{"$package\::DESTROY"} = \&Class::Prototyped::DESTROY;
    }
  }

  $tied->package($package);
  @{ $tied->isa } = qw(Class::Prototyped);
  $tied->vivified_parents(1);
  $tied->vivified_methods(1);

  bless $self, $package;    # in my own package

  $class = ref($class) || $class;    # allow object to provide a class
  unless ( @_ and grep { $_[ $_ * 2 ] eq 'class*' } 0 .. $#_ / 2 ) {
    no strict 'refs';
    if ( substr( $class, 0, &Class::Prototyped::Mirror::PREFIX_LENGTH ) ne
      &Class::Prototyped::Mirror::PREFIX && $class ne 'Class::Prototyped' )
    {
      $self->reflect->addSlots( 'class*' => $class );
    }
  }

  $self->reflect->addSlots(@_);
  return $self;
}

# Creates a copy of an object
sub clone {
  my $original = shift;
  ( ref($original) ? $original : 'Class::Prototyped' )
    ->new( $original->reflect->getSlots, @_ );
}

sub reflect {
  return Class::Prototyped::Mirror->new( $_[0] );
}

sub destroy {
  my $self = shift;
  my $mirror = $self->reflect;
  $mirror->deleteSlots( grep { $mirror->slotType($_) ne 'PARENT' } $mirror->slotNames );
}

# Remove my symbol table
sub DESTROY {
  my $self = shift;
  my $package = ref($self);
  if ( ( substr( $package, 0, &Class::Prototyped::Mirror::PREFIX_LENGTH ) eq
    &Class::Prototyped::Mirror::PREFIX )
    && ( $package ne 'Class::Prototyped' ) )
  {
    no strict 'refs';

    my $tied        = tied(%$self) or return;
    my $parentOrder = $tied->parentOrder;
    my $isa         = $tied->isa;
    my $slots       = $tied->slots;

    my (@deadIndices);
    foreach my $i ( 0 .. $#$parentOrder ) {
      my $parent        = $slots->{ $parentOrder->[$i] };
      my $parentPackage = ref($parent) || $parent;
      push ( @deadIndices, $i )
        unless scalar( keys %{"$parentPackage\::"} );
    }

    foreach my $i (@deadIndices) {
      delete( $slots->{ $parentOrder->[$i] } );
      splice( @$parentOrder, $i, 1 );
      splice( @$isa,         $i, 1 );
    }

    # this is required to re-cache @ISA
    delete ${"$package\::"}{'::ISA::CACHE::'};

    my $parent_DESTROY;
    my(@isa_queue) = @{"$package\::ISA"};
    my(%isa_cache);
    while (my $pkg = shift @isa_queue) {
      exists $isa_cache{$pkg} and next;
      my $code = *{"$pkg\::DESTROY"}{CODE};
      if (defined $code && $code != \&Class::Prototyped::DESTROY) {
        $parent_DESTROY = $code;
        last;
      }
      unshift(@isa_queue, @{"$pkg\::ISA"});
      $isa_cache{$pkg} = undef;
    }

    $self->destroy;                     # call the user destroy function

    $parent_DESTROY->($self) if defined $parent_DESTROY;

    $self->reflect->deleteSlots( $self->reflect->slotNames('PARENT') );

    foreach my $key ( keys %{"$package\::"} ) {
      delete ${"$package\::"}{$key};
    }

    # this only works because we're not a multi-level package:
    delete( $main::{"$package\::"} );

    delete( $Class::Prototyped::Mirror::parents{$package} );
  }
}

$Class::Prototyped::Mirror::ending = 0;
sub END { $Class::Prototyped::Mirror::ending = 1 }

package Class::Prototyped::Tied;
@Class::Prototyped::Tied::DONT_LIE_FOR = qw(Data::Dumper);

sub TIEHASH {
  bless {
    package          => undef,
    isa              => undef,
    parentOrder      => [],
    otherOrder       => [],
    slots            => {},
    vivified_parents => 0,
    vivified_methods => 0,
    },
    $_[0];
}

sub FIRSTKEY {
  $_[0]->{dont_lie} = 0;
  my $caller = ( caller(0) )[0];
  foreach my $i (@Class::Prototyped::Tied::DONT_LIE_FOR) {
    $_[0]->{dont_lie} = $caller eq $i and last;
  }
  $_[0]->{iter}        = 1;
  $_[0]->{cachedOrder} = $_[0]->slotOrder;

  unless ( $_[0]->{dont_lie} ) {
    my $slots = $_[0]->slots;
    @{ $_[0]->{cachedOrder} } =
      grep { !UNIVERSAL::isa( $slots->{$_}, 'CODE' ) }
      @{ $_[0]->{cachedOrder} };
  }
  return $_[0]->slotOrder->[0];
}

sub NEXTKEY {
  return $_[0]->{cachedOrder}->[ $_[0]->{iter}++ ];
}

sub EXISTS {
  exists $_[0]->{slots}->{ $_[1] } or return 0;
  UNIVERSAL::isa( $_[0]->{slots}->{ $_[1] }, 'CODE' ) or return 1;
  my $dont_lie = 0;
  my $caller = ( caller(0) )[0];
  foreach my $i (@Class::Prototyped::Tied::DONT_LIE_FOR) {
    $dont_lie = $caller eq $i and last;
  }
  return $dont_lie ? 1 : 0;
}

sub CLEAR {
  Carp::croak( "attempt to call CLEAR on the hash interface"
    . " of a Class::Prototyped object\n" );
}

sub package {
  return $_[0]->{package} unless @_ > 1;
  no strict 'refs';
  $_[0]->{isa}     = \@{"$_[1]\::ISA"};
  $_[0]->{package} = $_[1];
}

sub isa {
  $_[0]->{isa}
    or Carp::croak("attempt to access isa without defined package\n");
}

sub parentOrder {
  $_[0]->{parentOrder};
}

sub otherOrder {
  $_[0]->{otherOrder};
}

# Read-only.
sub slotOrder {
  [ @{ $_[0]->{parentOrder} }, @{ $_[0]->{otherOrder} } ];
}

sub slots {
  $_[0]->{slots};
}

sub vivified_parents {
  @_ > 1 ? $_[0]->{vivified_parents} = $_[1] : $_[0]->{vivified_parents};
}

sub vivified_methods {
  @_ > 1 ? $_[0]->{vivified_methods} = $_[1] : $_[0]->{vivified_methods};
}

#### Default Tied implementation
package Class::Prototyped::Tied::Default;
@Class::Prototyped::Tied::Default::ISA = qw(Class::Prototyped::Tied);

sub STORE {
  my $slots = $_[0]->slots;

  Carp::croak(
    "attempt to access non-existent slot through tied hash object interface"
    )
    unless exists $slots->{ $_[1] };

  Carp::croak(
    "attempt to access METHOD slot through tied hash object interface")
    if UNIVERSAL::isa( $slots->{ $_[1] }, 'CODE' );

  Carp::croak(
    "attempt to modify parent slot through the tied hash object interface")
    if substr( $_[1], -1 ) eq '*';

  $slots->{ $_[1] } = $_[2];
}

sub FETCH {
  my $slots = $_[0]->slots;

  Carp::croak(
"attempt to access non-existent slot through tied hash object interface:\n"
    . "$_[1]" )
    unless exists $slots->{ $_[1] };

  if ( UNIVERSAL::isa( $slots->{ $_[1] }, 'CODE' ) ) {
    my $dont_lie = 0;
    my $caller = ( caller(0) )[0];
    foreach my $i (@Class::Prototyped::Tied::DONT_LIE_FOR) {
      $dont_lie = $caller eq $i and last;
    }
    Carp::croak(
      "attempt to access METHOD slot through tied hash object interface")
      unless $dont_lie;
  }

  $slots->{ $_[1] };
}

sub DELETE {
  Carp::croak "attempt to delete a slot through tied hash object interface";
}

#### AutoVivifying Tied implementation
package Class::Prototyped::Tied::AutoVivify;
@Class::Prototyped::Tied::AutoVivify::ISA = qw(Class::Prototyped::Tied);

sub STORE {
  my $slots = $_[0]->slots;

  Carp::croak(
    "attempt to modify parent slot through the tied hash object interface")
    if substr( $_[1], -1 ) eq '*';

  if ( exists $slots->{ $_[1] } ) {
    Carp::croak(
      "attempt to access METHOD slot through tied hash object interface")
      if UNIVERSAL::isa( $slots->{ $_[1] }, 'CODE' );
  }
  else {
    my $slot = $_[1];
    $slots->{ $_[1] } = $_[2];
    my $implementation = bless sub {
      @_ > 1 ? $slots->{$slot} = $_[1] : $slots->{$slot};
    }, 'Class::Prototyped::FieldAccessor';
    no strict 'refs';
    local $^W = 0;    # suppress redefining messages.
    *{ $_[0]->package . "::$slot" } = $implementation;
    push ( @{ $_[0]->otherOrder }, $slot );
  }

  Carp::croak(
    "attempt to access non-existent slot through tied hash object interface"
    )
    unless exists $slots->{ $_[1] };

  $slots->{ $_[1] } = $_[2];
}

sub FETCH {
  my $slots = $_[0]->slots;

  if ( exists $slots->{ $_[1] }
    and UNIVERSAL::isa( $slots->{ $_[1] }, 'CODE' ) )
  {
    my $dont_lie = 0;
    my $caller = ( caller(0) )[0];
    foreach my $i (@Class::Prototyped::Tied::DONT_LIE_FOR) {
      $dont_lie = $caller eq $i and last;
    }
    Carp::croak(
      "attempt to access METHOD slot through tied hash object interface")
      unless $dont_lie;
  }

  $slots->{ $_[1] };
}

sub EXISTS {
  exists $_[0]->{slots}->{ $_[1] };
}

sub DELETE {
  my $slots = $_[0]->slots;

  if ( UNIVERSAL::isa( $slots->{ $_[1] }, 'CODE' )
    && ( caller(0) )[0] ne 'Data::Dumper' )
  {
    Carp::croak
      "attempt to delete METHOD slot through tied hash object interface";
  }

  my $package = $_[0]->package;
  my $slot    = $_[1];
  {
    no strict 'refs';
    my $name = "$package\::$slot";

    # save the glob...
    local *old = *{$name};

    # and restore everything else
    local *new;
    foreach my $type (qw(HASH IO FORMAT SCALAR ARRAY)) {
      my $elem = *old{$type};
      next if !defined($elem);
      *new = $elem;
    }
    *{$name} = *new;
  }
  my $otherOrder = $_[0]->otherOrder;
  @$otherOrder = grep { $_ ne $slot } @$otherOrder;
  delete $slots->{$slot};    # and delete the data/sub ref
}

# Everything that deals with modifying or inspecting the form
# of an object is done through a reflector.

package Class::Prototyped::Mirror;

sub PREFIX() { 'PKG0x' };
sub PREFIX_LENGTH() { 5 };

sub DEFAULT_TIED_INTERFACE { 'Class::Prototyped::Tied::Default'; }

sub new {
  my $object;
  if ( ref( $_[1] ) ) {
    $object = $_[1];
  }
  else {
    no strict 'refs';

    unless ( $object = $Class::Prototyped::Mirror::objects{ $_[1] } ) {
      my (%self);
      tie %self, &Class::Prototyped::Mirror::DEFAULT_TIED_INTERFACE();
      $object = $Class::Prototyped::Mirror::objects{ $_[1] } = \%self;
      tied(%self)->package( $_[1] );
      bless $object, $_[1];
    }
  }
  bless \$object, $_[0];
}

#### Interface to tied object

sub autoloadCall {
  my $mirror  = shift;
  my $package = $mirror;
  no strict 'refs';
  my $call = ${"$package\::AUTOLOAD"};
  $call =~ s/.*:://;
  return $call;
}

sub package {
  ref( ${ $_[0] } );
}

sub _isa {
  tied( %{ ${ $_[0] } } )->isa;
}

sub _parentOrder {
  my $tied = tied( %{ ${ $_[0] } } );
  $_[0]->_autovivify_parents unless $tied->vivified_parents;
  $tied->parentOrder;
}

sub _otherOrder {
  my $tied = tied( %{ ${ $_[0] } } );
  $_[0]->_autovivify_parents unless $tied->vivified_methods;
  $tied->otherOrder;
}

sub _slotOrder {
  my $tied = tied( %{ ${ $_[0] } } );
  $_[0]->_autovivify_parents unless $tied->vivified_parents;
  $_[0]->_autovivify_methods unless $tied->vivified_methods;
  $tied->slotOrder;
}

sub _slots {
  my $tied = tied( %{ ${ $_[0] } } );
  $_[0]->_autovivify_parents unless $tied->vivified_parents;
  $_[0]->_autovivify_methods unless $tied->vivified_methods;
  $tied->slots;
}

sub _vivified_parents {
  @_ > 1 ? tied( %{ ${ $_[0] } } )->vivified_parents( $_[1] ) :
    tied( %{ ${ $_[0] } } )->vivified_parents;
}

sub _vivified_methods {
  @_ > 1 ? tied( %{ ${ $_[0] } } )->vivified_methods( $_[1] ) :
    tied( %{ ${ $_[0] } } )->vivified_methods;
}

#### Autovivifivation support

sub _autovivify_parents {
  return if $_[0]->_vivified_parents;

  my $mirror = shift;
  $mirror->_vivified_parents(1);
  my $package     = $mirror->package;
  my $parentOrder = $mirror->_parentOrder;
  my $isa         = $mirror->_isa;
  my $slots       = $mirror->_slots;

  if ( scalar( grep { UNIVERSAL::isa( $_, 'Class::Prototyped' ) } @$isa )
    && $isa->[-1] ne 'Class::Prototyped' )
  {
    push ( @$isa, 'Class::Prototyped' );
    no strict 'refs';
    delete ${"$package\::"}{'::ISA::CACHE::'};  # re-cache @ISA
  }

  if ( @{$parentOrder} ) {
    Carp::croak( "attempt to autovivify in the "
      . "presence of an existing parentOrder\n" . "package: $package" );
  }
  my @isa = @$isa;
  pop (@isa) if scalar(@isa) && $isa[-1] eq 'Class::Prototyped';

  foreach my $parentPackage (@isa) {
    my $count = '';
    my $slot  = "$parentPackage$count*";
    while ( exists $slots->{$slot} || $slot eq 'self*' ) {
      $slot = $parentPackage . ( ++$count ) . '*';
    }
    push ( @$parentOrder, $slot );
    $slots->{$slot} = $parentPackage;
  }
}

sub _autovivify_methods {
  return if $_[0]->_vivified_methods;

  my $mirror = shift;
  $mirror->_vivified_methods(1);
  my $package    = $mirror->package;
  my $otherOrder = $mirror->_otherOrder;
  my $slots      = $mirror->_slots;

  no strict 'refs';
  foreach my $slot ( grep { $_ ne 'DESTROY' } keys %{"$package\::"} ) {
    my $code = *{"$package\::$slot"}{CODE} or next;
    ref($code) ne 'Class::Prototyped::FieldAccessor' or next;
    Carp::croak("the slot self* is inviolable") if $slot eq 'self*';

    if ( exists $slots->{$slot} ) {
      Carp::croak("you overwrote a slot via an include $slot")
        if !UNIVERSAL::isa( $slots->{$slot}, 'CODE' )
        || $slots->{$slot} != $code;
    }
    else {
      push ( @$otherOrder, $slot );
      $slots->{$slot} = $code;
    }
  }
}

sub object {
  $_[0]->_autovivify_parents;
  $_[0]->_autovivify_methods;
  ${ $_[0] };
}

sub class {
  return $_[0]->_slots->{'class*'};
}

sub dump {
  eval "package main; use Data::Dumper;"
    unless ( scalar keys(%Data::Dumper::) );

  Data::Dumper->Dump( [ $_[0]->object ], [ $_[0]->package ] );
}

sub addSlots {
  my $mirror = shift;
  my (@addSlots) = @_;

  Carp::croak("odd number of arguments to addSlots\n")
    if scalar(@addSlots) % 2;

  my $package     = $mirror->package;
  my $slots       = $mirror->_slots;
  my $parentOrder = $mirror->_parentOrder;
  my $otherOrder  = $mirror->_otherOrder;

  while ( my ( $slot, $value ) = splice( @addSlots, 0, 2 ) ) {
    my $parent_header    = 0;
    my $superable_method = 0;

    my $isCode = UNIVERSAL::isa( $value, 'CODE' );

    if ($isCode) {

      # Slots that end in '!' mean that the method is superable
      if ( substr( $slot, -1 ) eq '!' ) {
        $slot = substr( $slot, 0, -1 );
        $superable_method = 1;
      }
    }
    else {

      # Slots that end in '**' mean to push the slot
      # to the front of the parents list.
      if ( substr( $slot, -2 ) eq '**' ) {
        $slot = substr( $slot, 0, -1 );    # xyz** => xyz*
        $parent_header = 1;
      }

      # Slots that are named just '*' or '**' get their names from
      # their package name.
      if ( $slot eq '*' ) {
        $slot = ( ref($value) || $value ) . $slot;
      }

      Carp::croak("the slot self* is inviolable") if $slot eq 'self*';
    }

    if ( $slot eq 'DESTROY'
      && substr( $package, 0, PREFIX_LENGTH ) eq PREFIX )
    {
      Carp::croak("cannot replace DESTROY method for unnamed objects");
    }

    $mirror->deleteSlots($slot) if exists( $slots->{$slot} );

    $slots->{$slot} = $value;    #everything goes into the slots!!!!!

    if ( !$isCode && substr( $slot, -1 ) eq '*' ) {    # parent slot?
      unless ( UNIVERSAL::isa( $value, 'Class::Prototyped' )
        || ( ref( \$value ) eq 'SCALAR' && defined $value ) )
      {
        Carp::croak( "attempt to add parent that isn't a "
          . "Class::Prototyped or package name\n"
          . "package: $package slot: $slot parent: $value" );
      }

      if ( UNIVERSAL::isa( $value, $package ) ) {
        Carp::croak( "attempt at recursive inheritance\n"
          . "parent $value is a package $package" );
      }

      my $parentPackage = ref($value) || $value;

      if ( substr( $parentPackage, 0, PREFIX_LENGTH ) eq PREFIX ) {
        $Class::Prototyped::Mirror::parents{$package}->{$slot} = $value;
      }
      else {
        Carp::carp(
"it is recommended to use ->reflect->include for mixing in named files."
          )
          if $parentPackage =~ /\.p[lm]$/i;

        no strict 'refs';
        if ( !ref($value)
          && !( scalar keys( %{"$parentPackage\::"} ) ) )
        {
          $mirror->include($parentPackage);
        }
      }

      my $isa         = $mirror->_isa;
      my $splice_point = $parent_header ? 0 : @$parentOrder;
      splice( @$isa, $splice_point, 0, $parentPackage );
      {
        #Defends against ISA caching problems
        no strict 'refs';
        delete ${"$package\::"}{'::ISA::CACHE::'};
      }
      splice( @$parentOrder, $splice_point, 0, $slot );
    }
    else {

      if ( exists( $Class::Prototyped::overloadable_symbols{$slot} ) ) {
        Carp::croak("Can't overload slot with non-CODE\nslot: $slot")
          unless $isCode;
        eval "package $package;
          use overload '$slot' => \$value, fallback => 1;
              bless \$object, \$package;";
        Carp::croak( "Eval failed while defining overload\n"
          . "operation: \"$slot\" error: $@" )
          if $@;
      }
      else {
        my $implementation;

        if ($superable_method) {

          package Class::Prototyped::Mirror::SUPER;
          $implementation = sub {
            local $Class::Prototyped::Mirror::SUPER::package =
              $package;
            shift->$value(@_);
          };

          package Class::Prototyped::Mirror;
        }
        elsif ($isCode) {
          $implementation = $value;
        }
        else {
          $implementation = bless sub {
            @_ > 1 ? $slots->{$slot} = $_[1] : $slots->{$slot};
          }, 'Class::Prototyped::FieldAccessor';
        }
        no strict 'refs';
        local $^W = 0;    # suppress redefining messages.
        *{"$package\::$slot"} = $implementation;
      }
      push ( @$otherOrder, $slot );
    }
  }

  return $mirror;
}

*addSlot = \&addSlots;    # alias addSlot to addSlots

# $obj->reflect->deleteSlots( name [, name [...]] );
sub deleteSlots {
  my $mirror = shift;
  my (@deleteSlots) = @_;

  my $package     = $mirror->package;
  my $slots       = $mirror->_slots;
  my $parentOrder = $mirror->_parentOrder;
  my $otherOrder  = $mirror->_otherOrder;
  my $isa         = $mirror->_isa;

  foreach my $slot (@deleteSlots) {
    $slot = substr( $slot, 0, -1 ) if substr( $slot, -2 ) eq '**';
    $slot = substr( $slot, 0, -1 ) if substr( $slot, -1 ) eq '!';

    next if !exists( $slots->{$slot} );

    my $value = $slots->{$slot};

    if ( substr( $slot, -1 ) eq '*' ) {    # parent slot
      my $index = 0;
      1 while ( $parentOrder->[$index] ne $slot
        and $index++ < @$parentOrder );

      if ( $index < @$parentOrder ) {
        splice( @$parentOrder, $index, 1 );
        splice( @$isa, $index, 1 );
        {
          #Defends against ISA caching problems
          no strict 'refs';
          delete ${"$package\::"}{'::ISA::CACHE::'};
        }
      }
      else {    # not found

        if ( !$Class::Prototyped::Mirror::ending ) {
          Carp::cluck "couldn't find $slot in $package\n";
          $DB::single = 1;
        }
      }

      if ( defined($value) ) {
        my $parentPackage = ref($value);
        if ( substr( $parentPackage, 0, PREFIX_LENGTH ) eq PREFIX ) {
          delete
            ( $Class::Prototyped::Mirror::parents{$package}->{$slot}
          );
        }
      }
      else {

        if ( !$Class::Prototyped::Mirror::ending ) {
          Carp::cluck "slot undef for $slot in $package\n";
          $DB::single = 1;
        }
      }
    }
    else {

      if ( exists( $Class::Prototyped::overloadable_symbols{$slot} ) ) {
        Carp::croak(
          "Perl segfaults when the last overload is removed. Boom!\n")
          if ( 1 == grep {
            exists( $Class::Prototyped::overloadable_symbols{$_} );
        } keys(%$slots) );

        my $object = $mirror->object;

        eval "package $package;
          no overload '$slot';
              bless \$object, \$package;"
          ;    # dummy bless so that overloading works.
        Carp::croak( "Eval failed while removing overload\n"
          . "operation: \"$slot\" error: $@" )
          if $@;
      }
      else {    # we have a method by that name; delete it
        no strict 'refs';
        my $name = "$package\::$slot";

        # save the glob...
        local *old = *{$name};

        # and restore everything else
        local *new;
        foreach my $type (qw(HASH IO FORMAT SCALAR ARRAY)) {
          my $elem = *old{$type};
          next if !defined($elem);
          *new = $elem;
        }
        *{$name} = *new;
      }
      @$otherOrder = grep { $_ ne $slot } @$otherOrder;
    }
    delete $slots->{$slot};    # and delete the data/sub ref
  }

  return $mirror;
}

*deleteSlot = \&deleteSlots;    # alias deleteSlot to deleteSlots

sub super_slow {
  return shift->super_fast(@_)
    if ( ( caller(1) )[0] eq 'Class::Prototyped::Mirror::SUPER' );
  return shift->super_fast(@_)
    if ( ( caller(2) )[0] eq 'Class::Prototyped::Mirror::SUPER' );
  Carp::croak(
    "attempt to call super on a method that was defined without !\n"
    . "method: " . $_[1] );
}

*super = \&super_slow unless defined( *super{CODE} );

sub super_fast {
  my $mirror  = shift;
  my $message = shift;

  $message or Carp::croak("you have to pass the method name to super");

  my $object = $mirror->object;

  my (@isa);
  {
    no strict 'refs';
    @isa = @{ $Class::Prototyped::Mirror::SUPER::package . '::ISA' };
  }
  my $method;

  foreach my $parentPackage (@isa) {
    $method = UNIVERSAL::can( $parentPackage, $message );
    last if $method;
  }
  $method
    or Carp::croak("could not find super in parents\nmessage: $message");
  $method->( $object, @_ );
}

sub slotNames {
  my $mirror = shift;
  my $type   = shift;

  my @slotNames = @{ $mirror->_slotOrder };
  if ($type) {
    @slotNames = grep { $mirror->slotType($_) eq $type } @slotNames;
  }
  return wantarray ? @slotNames : \@slotNames;
}

sub slotType {
  my $mirror   = shift;
  my $slotName = shift;

  my $slots = $mirror->_slots;
  Carp::croak(
    "attempt to determine slotType for unknown slot\nslot: $slotName")
    unless exists $slots->{$slotName};
  return 'PARENT' if substr( $slotName, -1 ) eq '*';
  return 'METHOD' if UNIVERSAL::isa( $slots->{$slotName}, 'CODE' );
  return 'FIELD';
}

# may return dups
sub allSlotNames {
  my $mirror = shift;
  my $type   = shift;

  my @slotNames;
  foreach my $parent ( $mirror->withAllParents() ) {
    my $mirror = Class::Prototyped::Mirror->new($parent);
    push ( @slotNames, $mirror->slotNames($type) );
  }
  return wantarray ? @slotNames : \@slotNames;
}

sub parents {
  my $mirror = shift;

  my $object = $mirror->object;
  my $slots  = $mirror->_slots;
  return map { $slots->{$_} } $mirror->slotNames('PARENT');
}

sub allParents {
  my $mirror = shift;
  my $retval = shift || [];
  my $seen   = shift || {};

  foreach my $parent ( $mirror->parents ) {
    next if $seen->{$parent}++;
    push @$retval, $parent;
    my $mirror = Class::Prototyped::Mirror->new($parent);
    $mirror->allParents( $retval, $seen );
  }
  return wantarray ? @$retval : $retval;
}

sub withAllParents {
  my $mirror = shift;

  my $object = $mirror->object;
  my $retval = [$object];
  my $seen   = { $object => 1 };
  $mirror->allParents( $retval, $seen );
}

# getSlot returns both the slotName and the slot in array context
# so that it can append !'s to superable methods, so that getSlots does the
# right thing, so that clone does the right thing.
# However, in scalar context, it just returns the value.

sub getSlot {
  my $mirror   = shift;
  my $slotName = shift;

  my $value =
    ( $slotName ne 'self*' ) ? $mirror->_slots->{$slotName} : $mirror->object;

  if ( defined($value) and UNIVERSAL::isa( $value, 'CODE' ) ) {
    no strict 'refs';
    $slotName .= '!' if \&{ $mirror->package . "::$slotName" } != $value;
  }
  return wantarray ? ( $slotName, $value ) : $value;
}

sub getSlots {
  my $mirror = shift;
  my $type   = shift;

  my @retval = map { $mirror->getSlot($_) } $mirror->slotNames($type);
  return wantarray ? @retval : \@retval;
}

sub promoteParents {
  my $mirror = shift;
  my (@newOrder) = @_;

  my $parentOrder = $mirror->_parentOrder;
  my $slots       = $mirror->_slots;

  my %seen;
  foreach my $slot (@newOrder) {
    $seen{$slot}++;
    if ( $seen{$slot} > 1 || !exists( $slots->{$slot} ) ) {
      Carp::croak("promoteParents called with bad order list\nlist: @_");
    }
    else {
      @{$parentOrder} = grep { $_ ne $slot } @{$parentOrder};
    }
  }

  @{$parentOrder} = ( @newOrder, @{$parentOrder} );

  my $isa = $mirror->_isa;
  @$isa =
    ( ( map { ref( $slots->{$_} ) ? ref( $slots->{$_} ) : $slots->{$_} }
    @{$parentOrder} ), 'Class::Prototype' );

  # this is required to re-cache @ISA
  my $package     = $mirror->package;
  no strict 'refs';
  delete ${"$package\::"}{'::ISA::CACHE::'};
}

sub wrap {
  my $mirror        = shift;
  my $class         = $mirror->class || 'Class::Prototyped';
  my $wrapped       = $class->new;
  my $wrappedMirror = $wrapped->reflect;

  # add all the slots from the original object
  $wrappedMirror->addSlots( $mirror->getSlots );

  # delete all my original slots
  # so that the wrapped gets called
  $mirror->deleteSlots( $mirror->slotNames );
  $mirror->addSlots( @_, 'wrapped**' => $wrapped );
  $mirror;
}

sub unwrap {
  my $mirror  = shift;
  my $wrapped = $mirror->getSlot('wrapped*')
    or Carp::croak "unwrapping without a wrapped\n";
  my $wrappedMirror = $wrapped->reflect;
  $mirror->deleteSlots( $mirror->slotNames );
  $mirror->addSlots( $wrappedMirror->getSlots );

  #  $wrappedMirror->deleteSlots( $wrappedMirror->slotNames );
  $mirror;
}

sub delegate {
  my $mirror = shift;

  while ( my ( $name, $value ) = splice( @_, 0, 2 ) ) {
    my @names = ( UNIVERSAL::isa( $name, 'ARRAY' ) ? @$name : $name );
    my @conflicts;

    foreach my $slotName (@names) {
      push ( @conflicts, grep { $_ eq $slotName } $mirror->slotNames );
    }
    Carp::croak(
      "delegate would cause conflict with existing slots\n" . "pattern: "
      . join ( '|',  @names ) . " , conflicting slots: "
      . join ( ', ', @conflicts ) )
      if @conflicts;

    my $delegateMethod;
    if ( UNIVERSAL::isa( $value, 'ARRAY' ) ) {
      $delegateMethod = $value->[1];
      $value = $value->[0];
    }
    my $delegate = $mirror->getSlot($value) || $value;
    Carp::croak("Can't delegate to a subroutine\nslot: $name")
      if ( UNIVERSAL::isa( $delegate, 'CODE' ) );

    foreach my $slotName (@names) {
      my $method = defined($delegateMethod) ? $delegateMethod : $slotName;
      $mirror->addSlot(
        $slotName => sub {
          shift;    # discard original recipient
          $delegate->$method(@_);
        }
      );
    }
  }
}

sub findImplementation {
  my $mirror   = shift;
  my $slotName = shift;

  my $object = $mirror->object;
  UNIVERSAL::can( $object, $slotName ) or return;

  my $slots = $mirror->_slots;
  exists $slots->{$slotName} and return wantarray ? 'self*' : $object;

  foreach my $parentName ( $mirror->slotNames('PARENT') ) {
    my $mirror =
      Class::Prototyped::Mirror->new(
      scalar( $mirror->getSlot($parentName) ) );
    if (wantarray) {
      my (@retval) = $mirror->findImplementation($slotName);
      scalar(@retval) and return ( $parentName, @retval );
    }
    else {
      my $retval = $mirror->findImplementation($slotName);
      $retval and return $retval;
    }
  }
  Carp::croak("fatal error in findImplementation");
}

# load the given file or package in the receiver's namespace
# Note that no import is done.
# Croaks on an eval error
#
#   $mirror->include('Package');
#   $mirror->include('File.pl');
#
#   $mirror->include('File.pl', 'thisObject');
#   makes thisObject() return the object into which the include
#   is happening (as long as you don't change packages in the
#   included code)
sub include {
  my $mirror       = shift;
  my $name         = shift;
  my $accessorName = shift;

  $name = "'$name'" if $name =~ /\.p[lm]$/i;

  my $object  = $mirror->object;
  my $package = $mirror->package;
  my $text    = "package $package;\n";
  $text .= "*$package\::$accessorName = sub { \$object };\n"
    if defined($accessorName);

  #  $text .= "sub $accessorName { \$object };\n" if defined($accessorName);
  $text .= "require $name;\n";
  my $retval = eval $text;
  Carp::croak("include failed\npackage: $package include: $name error: $@")
    if $@;

  if ( substr( $name, -1 ) eq "'" ) {
    $mirror->_vivified_methods(0);
    $mirror->_autovivify_methods;
  }

  $mirror->deleteSlots($accessorName) if defined($accessorName);
}

1;
__END__

=head1 NAME

C<Class::Prototyped> - Fast prototype-based OO programming in Perl

=head1 SYNOPSIS

    use blib;
    use strict;
    use Class::Prototyped ':EZACCESS';

    $, = ' '; $\ = "\n";

    my $p = Class::Prototyped->new(
      field1 => 123,
      sub1   => sub { print "this is sub1 in p" },
      sub2   => sub { print "this is sub2 in p" }
    );

    $p->sub1;
    print $p->field1;
    $p->field1('something new');
    print $p->field1;

    my $p2 = Class::Prototyped::new(
      'parent*' => $p,
      field2    => 234,
      sub2      => sub { print "this is sub2 in p2" }
    );

    $p2->sub1;
    $p2->sub2;
    print ref($p2), $p2->field1, $p2->field2;
    $p2->field1('and now for something different');
    print ref($p2), $p2->field1;

    $p2->addSlots( sub1 => sub { print "this is sub1 in p2" } );
    $p2->sub1;

    print ref($p2), "has slots", $p2->reflect->slotNames;

    $p2->reflect->include( 'xx.pl' ); # includes xx.pl in $p2's package
    print ref($p2), "has slots", $p2->reflect->slotNames;
    $p2->aa();    # calls aa from included file xx.pl

    $p2->deleteSlots('sub1');
    $p2->sub1;

=head1 DESCRIPTION

This package provides for efficient and simple prototype-based programming
in Perl. You can provide different subroutines for each object, and also
have objects inherit their behavior and state from another object.

The structure of an object is inspected and modified through I<mirrors>, which
are created by calling B<reflect> on an object or class that inherits from
C<Class::Prototyped>.

=head1 CONCEPTS

=head2 Slots

C<Class::Prototyped> borrows very strongly from the language Self (see
http://www.sun.com/research/self for more information).  The core concept in
Self is the concept of a slot.  Think of slots as being entries in a hash,
except that instead of just pointing to data, they can point to objects, code,
or parent objects.

So what happens when you send a message to an object (that is to say, you make a
method call on the object)?  First, Perl looks for that slot in the object.  If it
can't find that slot in the object, it searches for that slot in one of the
object's parents (which we'll come back to later).  Once it finds the slot, if
the slot is a block of code, it evaluates the code and returns the return
value.  If the slot references data, it returns that data.  If you assign to a
data slot (through a method call), it modifies the data.

Distinguishing data slots and method slots is easy - the latter are references
to code blocks, the former are not.  Distinguishing parent slots is not so
easy, so instead a simple naming convention is used.  If the name of the slot
ends in an asterisk, the slot is a parent slot.  If you have programmed in
Self, this naming convention will feel very familiar.

=head2 Reflecting

In Self, to examine the structure of an object, you use a mirror.  Just like
using his shield as a mirror enabled Perseus to slay Medusa, holding up a
mirror enables us to look upon an object's structure without name space
collisions.

Because the mirror methods C<super>, C<addSlot>(C<s>), C<deleteSlot>(C<s>), and
C<getSlot>(C<s>) are called frequently on objects, there is an import keyword
C<:EZACCESS> that adds methods to the object space that call the appropriate
reflected variants.

=head2 Classes vs. Objects

In Self, everything is an object and there are no classes at all.  Perl, for
better or worse, has a class system based on packages.  We decided that it
would be better not to throw out the conventional way of structuring
inheritance hierarchies, so in C<Class::Prototyped>, classes are first-class
objects.

However, objects are not first-class classes.  To understand this dichotomy, we
need to understand that there is a difference between the way "classes" and the
way "objects" are expected to behave.  The central difference is that "classes"
are expected to persist whether or not that are any references to them.  If you
create a class, the class exists whether or not it appears in anyone's @ISA and
whether or not there are any objects in it.  Once a class is created, it
persists until the program terminates.

Objects, on the other hand, should follow the normal behaviors of
reference-counted destruction - once the number of references to them drops to
zero, they should miraculously disappear - the memory they used needs to be
returned to Perl, their DESTROY methods need to be called, and so forth.

Since we don't require this behavior of classes, it's easy to have a way to get
from a package name to an object - we simply stash the object that implements
the class in C<$Class::Prototyped::Mirror::objects{$package}>.  But we can't do
this for objects, because if we do the object will persist forever, for that
reference will always exist.

Weak references would solve this problem, but weak references are still
considered alpha and unsupported (C<$WeakRef::VERSION = 0.01>), and we didn't
want to make C<Class::Prototyped> dependent on such a module.

So instead, we differentiate between classes and objects.  In a nutshell, if an
object has an explicit package name (I<i.e.> something other than the
auto-generated one), it is considered to be a class, which means it persists
even if the object goes out of scope.

To create such an object, use the C<newPackage> method, like so:

    {
      my $object = Class::Prototyped->newPackage('MyClass',
          field => 1,
          double => sub {$_[0]->field*2}
        );
    }

    print MyClass->double,"\n";

Notice that the class persists even though C<$object> goes out of scope.  If
C<$object> were created with an auto-generated package, that would not be true.
Thus, for instance, it would be a B<very, very, very> bad idea to add the
package name of an object as a parent to another object - when the first object
goes out of scope, the package will disappear, but the second object will still
have it in it's C<@ISA>.

Except for the crucial difference that you should B<never, ever, ever> make use
of the package name for an object for any purpose other than printing it to the
screen, objects and classes are simply different ways of inspecting the same
entity.

To go from an object to a package, you can do one of the following:

    $package = ref($object);
    $package = $object->reflect->package;

The two are equivalent, although the first is much faster.  Just remember, if
C<$object> is in an auto-generated package, don't do anything with that
C<$package> but print it.

To go from a package to an object, you do this:

    $object = $package->reflect->object;

Note that C<$package> is simple the name of the package - the following code
works perfectly:

    $object = MyClass->reflect->object;

But keep in mind that C<$package> has to be a class, not an auto-generated
package name for an object.

=head2 Class Manipulation

This lets us have tons of fun manipulating classes at run time. For instance,
if you wanted to add, at run-time, a new method to the C<MyClass> class?
Assuming that the C<MyClass> inherits from C<Class::Prototyped> or that you
have specified C<:REFLECT> on the C<use Class::Prototyped> call, you simply
write:

    MyClass->reflect->addSlot(myMethod => sub {print "Hi there\n"});

Just as you can C<clone> objects, you can C<clone> classes that are derived
from C<Class::Prototyped>. This creates a new object that has a copy of all of
the slots that were defined in the class.  Note that if you simply want to be
able to use Data::Dumper on a class, calling MyClass->reflect->object is the
preferred approach.  Or simply use the C<dump> mirror method.

The code that implements reflection on classes automatically creates slot
names for package methods as well as parent slots for the entries in C<@ISA>.
This means that you can code classes like you normally do - by
doing the inheritance in C<@ISA> and writing package methods.

If you manually add subroutines to a package at run-time and want the slot
information updated properly (although this really should be done via the
addSlots mechanism, but maybe you're twisted:), you should do something like:

    $package->reflect->_vivified_methods(0);
    $package->reflect->_autovivify_methods;

=head2 Parent Slots

Adding parent slots is no different than adding normal slots - the naming
scheme takes care of differentiating.

Thus, to add C<$foo> as a parent to C<$bar>, you write:

    $bar->reflect->addSlot('fooParent*' => $foo);

However, keeping with our concept of classes as first class objects, you can
also write the following:

    $bar->reflect->addSlot('mixIn*' => 'MyMix::Class');

It will automatically require the module in the namespace of C<$bar> and
make the module a parent of the object.
This can load a module from disk if needed.

If you're lazy, you can add parents without names like so:

    $bar->reflect->addSlot('*' => $foo);

The slots will be automatically named for the package passed in - in the case
of C<Class::Prototyped> objects, the package is of the form C<PKG0x12345678>.
In the following example, the parent slot will be named C<MyMix::Class*>.

    $bar->reflect->addSlot('*' => 'MyMix::Class');

Parent slots are added to the inheritance hierarchy in the order that they
were added.  Thus, in the following code, slots that don't exist in C<$foo>
are looked up in C<$fred> (and all of its parent slots) before being looked up
in C<$jill>.

    $foo->reflect->addSlots('fred*' => $fred, 'jill*' => $jill);

Note that C<addSlot> and C<addSlots> are identical - the variants exist only
because it looks ugly to add a single slot by calling C<addSlots>.

If you need to reorder the parent slots on an object, look at
C<promoteParents>.  That said, there's a shortcut for prepending a slot to
the inheritance hierarchy.  Simply add a second asterisk to the end of the
slotname when calling C<addSlots>.  The second asterisk will be automatically
stripped from the end of the slotname before the slot is prepended to the
hierarchy.

Finally, in keeping with our principle that classes are first-class object,
the inheritance hierarchy of classes can be modified through C<addSlots> and
C<deleteSlots>, just like it can for objects.  The following code adds the
C<$foo> object as a parent of the MyClass class, prepending it to the
inheritance hierarchy:

    MyClass->reflect->addSlots('foo**' => $foo);

=head2 Operator Overloading

In C<Class::Prototyped>, you do operator overloading by adding slots with the
right name.  First, when you do the B<use> on C<Class::Prototyped>, make sure
to pass in C<:OVERLOAD> so that the operator overloading support is enabled.

Then simply pass the desired methods in as part of the object creation like
so:

    $foo = Class::Prototyped->new(
        value => 3,
        '""'  => sub { my $self = shift; $self->value( $self->value + 1 ) },
    );

This creates an object that increments its field C<value> by one and returns
that incremented value whenever it is stringified.

Since there is no way to find out which operators are overloaded, if you add
overloading to a I<class> through the use of C<use overload>, that behavior
will not show up as slots when reflecting on the class. However, C<addSlots>
B<does> work for adding operator overloading to classes.  Thus, the following
code does what is expected:

    package MyClass;
    @MyClass::ISA = qw(Class::Prototyped);

    MyClass->reflect->addSlots(
        '""' => sub { my $self = shift; $self->value( $self->value + 1 ) },
    );

    package main;

    $foo = MyClass->new( value => 2 );
    print $foo, "\n";

Provided, of course, that C<MyClass> finds its way into C<$foo> as a parent
during C<$foo>'s instantiation.

=head2 Object Class

The special parent slot C<class*> is used to indicate object class.  When you
create C<Class::Prototyped> objects, the C<class*> slot is B<not> set.  If,
however, you create objects by calling C<new> on a class that inherits from
C<Class::Prototyped>, the slot C<class*> points to the package name.

The value of this slot can be returned quite easily like so:

  $foo->reflect->class;

Class is set when C<new> is called on a package or object that has a named
package.

=head2 Calling Inherited Methods

Methods (and fields) inherited from prototypes or classes are I<not>
generally available using the usual Perl C<$self-E<gt>SUPER::something()>
mechanism.

The reason for this is that C<SUPER::something> is hardcoded to the package in
which the subroutine (anonymous or otherwise) was defined.  For the vast
majority of programs, this will be C<main::>, and thus <SUPER::> will look in
C<@main::ISA> (not a very useful place to look).

To get around this, a very clever wrapper can be automatically placed around
your subroutine that will automatically stash away the package to which the
subroutine is attached.  From within the subroutine, you can use the C<super>
mirror method to make an inherited call.  However, because we'd rather not
write code that attempts to guess as to whether or not the subroutine uses the
C<super> construct, you have to tell C<addSlots> that the subroutine needs to
have this wrapper placed around it.  To do this, simply append an "!" to the
end of the slot name.  This "!" does not belong to the slot name - it is
simply an indicator to C<addSlots> that the subroutine needs to have C<super>
support enabled.

For instance, the following code will work:

    use Class::Prototyped;

    my $p1 = Class::Prototyped->new(
        method => sub { print "this is method in p1\n" },
    );

    my $p2 = Class::Prototyped->new(
        '*'       => $p1,
        'method!' => sub {
            print "this is method in p2 calling method in p1: ";
            $_[0]->reflect->super('method');
        },
    );

To make things easier, if you specify C<:EZACCESS> during the import, C<super>
can be called directly on an object rather than through its mirror.

The other thing of which you need to be aware is copying methods from one
object to another.  The proper way to do this is like so:

  $foo->reflect->addSlot($bar->reflect->getSlot('method'));

When the C<getSlot> method is called in an array context, it returns both the
slot name and the slot.  If it notices that the slot in question is a method
and that it is a method wrapped so that inherited methods can be called, it
will automatically append an "!" to the returned slot name, thus making it
safe for use in C<addSlot>.

Finally, to help protect the code, the C<super> method is smart enough to
determine whether it was called within a wrapped subroutine.  If it wasn't, it
croaks, thus indicating that the method should have had an "!" appended to the
slot name when it was added.  If you wish to disable this checking (which will
improve the performance of your code, of course, but could result in B<very>
hard to trace bugs if you haven't been careful), see the import option
C<:SUPER_FAST>.


=head1 IMPORT OPTIONS

=over 4

=item :OVERLOAD

This configures the support in C<Class::Prototyped> for using operator
overloading.

=item :REFLECT

This defines UNIVERSAL::reflect to return a mirror for any class.
With a mirror, you can manipulate the class, adding or deleting methods,
changing its inheritance hierarchy, etc.

=item :EZACCESS

This adds the methods C<addSlot>, C<addSlots>, C<deleteSlot>, C<deleteSlots>,
C<getSlot>, C<getSlots>, and C<super> to C<Class::Prototyped>.

This lets you write:

  $foo->addSlot(myMethod => sub {print "Hi there\n"});

instead of having to write:

  $foo->reflect->addSlot(myMethod => sub {print "Hi there\n"});

The other methods in C<Class::Prototyped::Mirror> should be accessed through a
mirror (otherwise you'll end up with way too much name space pollution for
your objects:).

=item :SUPER_FAST

Switches over to the fast version of C<super> that doesn't check to see
whether methods that use inherited calls had "!" appended to their slot names.

=item :NEW_MAIN

Creates a C<new> function in C<main::> that creates new C<Class::Prototyped>
objects.  Thus, you can write code like:

  use Class::Prototyped qw(:NEW_MAIN :EZACCESS);

  my $foo = new(say_hi => sub {print "Hi!\n";});
  $foo->say_hi;

=item :TIED_INTERFACE

This allows you to specify the sort of tied interface you wish to offer when
code attempts to access a C<Class::Prototyped> object as a hash reference.
This option expects that the second parameter will specify either the package
name or an alias.  The currently known aliases are:

=over 4

=item default

This specifies C<Class::Prototyped::Tied::Default> as the tie class.  The
default behavior is to allow access to existing fields, but attempts to create
fields, access methods, or delete slots will croak.

=item autovivify

This specifies C<Class::Prototyped::Tied::AutoVivify> as the tie class.  The
behavior of this package allows access to existing fields, will automatically
create field slots if they don't exist, and will allow deletion of field slots.
Attempts to access or delete method or parent slots will croak.

=back

=back

=head1 C<Class::Prototyped> Methods

=head2 new() - Construct a new C<Class::Prototyped> object.

A new object is created.  If this is called on a class that inherits from
C<Class::Prototyped>, and C<class*> is not being passed as a slot in the
argument list, the slot C<class*> will be the first element in the inheritance
list.

The passed arguments are handed off to C<addSlots>.

For instance, the following will define a new C<Class::Prototyped> object with
two method slots and one field slot:

    my $foo = Class::Prototyped->new(
        field1 => 123,
        sub1   => sub { print "this is sub1 in foo" },
        sub2   => sub { print "this is sub2 in foo" },
    );

The following will create a new C<MyClass> object with one field slot and with
the parent object C<$bar> at the beginning of the inheritance hierarchy (just
before C<class*>, which points to C<MyClass>):

    my $foo = MyClass->new(
        field1  => 123,
        'bar**' => $bar,
    );

=head2 newPackage() - Construct a new C<Class::Prototyped> object in a
specific package.

Just like C<new>, but instead of creating the new object with an arbitrary
package name (actually, not entirely arbitrary - it's generally based on the
hash memory address), the first argument is used as the name of the package.

If the package name is already in use, this method will croak.

=head2 clone() - Duplicate me

Duplicates an existing object or class. and allows you to add or override
slots. The slot definition is the same as in B<new()>.

  my $p2 = $p1->clone(
      sub1 => sub { print "this is sub1 in p2" },
  );

It calls C<new> on the object to create the new object, so if C<new> has been
overriden, the overriden C<new> will be called.

=head2 reflect() - Return a mirror for the object or class

The structure of an object is modified by using a mirror.  This is the
equivalent of calling:

  Class::Prototyped::Mirror->new($foo);

=head2 destroy() - The destroy method for an object

You should never need to call this method.  However, you may want to override
it.  Because we had to directly specify C<DESTROY> for every object in order
to allow safe destruction during global destruction time when objects may
have already destroyed packages in their C<@ISA>, we had to hook C<DESTROY>
for every object.  To allow the C<destroy> behavior to be overridden, users
should specify a C<destroy> method for their objects (by adding the slot),
which will automatically be called by the C<Class::Prototyped::DESTROY>
method after the C<@ISA> has been cleaned up.

This method should be defined to allow inherited method calls (I<i.e.> should
use C<'destroy!'> to define the method) and should call
C<< $self->reflect->super('destroy'); >> at some point in the code.

Here is a quick overview of the default destruction behavior for objects:

=over 4

=item *

C<Class::Prototyped::DESTROY> is called because it is linked into the package
for all objects at instantiation time

=item *

All no longer existent entries are stripped from C<@ISA>

=item *

The inheritance hierarchy is searched for a C<DESTROY> method that is not
C<Class::Prototyped::DESTROY>.  This C<DESTROY> method is stashed away for
a later call.

=item *

The inheritance hierarchy is searched for a C<destroy> method and it is
called.  Note that the C<Class::Prototyped::destroy> method, which will
either be called directly because it shows up in the inheritance hierarchy or
will be called indirectly through calls to
C<< $self->reflect->super('destroy'); >>, will delete all non-parent slots from
the object.  It leaves parent slots alone because the destructors for the
parent slots should not be called until such time as the destruction of the
object in question is complete (otherwise inherited destructors might still
be executing, even though the object to which they belong has already been
destroyed).  This means that the destructors for objects referenced in
non-parent slots may be called, temporarily interrupting the execution
sequence in C<Class::Prototyped::destroy>.

=item *

The previously stashed C<DESTROY> method is called.

=item *

The parent slots for the object are finally removed, thus enabling the
destructors for any objects referenced in those parent slots to run.

=item *

Final C<Class::Prototyped> specific cleanup is run.

=back

=head2 super() - Call a method defined in a parent

If you use the :EZACCESS import flag, you will have C<super> defined for use
to call inherited methods (see I<Calling Inherited Methods> above).

=head1 C<Class::Prototyped::Mirror> Methods

These are the methods you can call on the mirror returned from a C<reflect>
call. If you specify :REFLECT in the C<use Class::Prototyped> line, addSlot,
addSlots, deleteSlot, and deleteSlots will be callable on C<Class::Prototyped>
objects as well.

=head2 autoloadCall()

If you add an AUTOLOAD slot to an object, you will need to get the name of the
subroutine being called. C<autoloadCall()> returns the name of the subroutine,
with the package name stripped off.

=head2 package() - Returns the name of the package for the object

=head2 object() - Returns the object itself

=head2 class() - Returns the C<class*> slot for the underlying object

=head2 dump() - Returns a Data::Dumper string representing the object

=head2 addSlot() - An alias for addSlots

=head2 addSlots() - Add or override slot definitions

Allows you to add or override slot definitions in the receiver.

    $p->reflect->addSlots(
        fred        => 'this is fred',
        doSomething => sub { print 'doing something with ' . $_[1] },
    );
    $p->doSomething( $p->fred );

=head2 deleteSlot() - An alias for deleteSlots

=head2 deleteSlots() - Delete one or more of the receiver's slots by name

This will let you delete existing slots in the receiver.
If those slots were defined earlier in the prototype chain,
those earlier definitions will now be available.

    my $p1 = Class::Prototyped->new(
        field1 => 123,
        sub1   => sub { print "this is sub1 in p1" },
        sub2   => sub { print "this is sub2 in p1" }
    );
    my $p2 = Class::Prototyped->new(
        'parent*' => $p1,
        sub1      => sub { print "this is sub1 in p2" },
    );
    $p2->sub1;    # calls $p2.sub1
    $p2->reflect->deleteSlots('sub1');
    $p2->sub1;    # calls $p1.sub1
    $p2->reflect->deleteSlots('sub1');
    $p2->sub1;    # still calls $p1.sub1

=head2 super() - Call a method defined in a parent

=head2 slotNames() - Returns a list of all the slot names

This is passed an optional type parameter.  If specified, it should be one of
C<'FIELD'>, C<'METHOD'>, or C<'PARENT'>.  For instance, the following will
print out a list of all slots of an object:

  print join(', ', $obj->reflect->slotNames)."\n";

The following would print out a list of all field slots:

  print join(', ', $obj->reflect->slotNames('FIELD')."\n";

The parent slot names are returned in the same order for which inheritance is
done.

=head2 slotType() - Given a slot name, determines the type

This returns C<'FIELD'>, C<'METHOD'>, or C<'PARENT'>.
It croaks if the slot is not defined for that object.

=head2 parents() - Returns a list of all parents

Returns a list of all parent object (or package names) for this object.

=head2 allParents() - Returns a list of all parents in the hierarchy

Returns a list of all parent objects (or package names) in the object's
hierarchy.

=head2 withAllParents() - Same as above, but includes self in the list

=head2 allSlotNames() - Returns a list of all slot names
defined for the entire inheritance hierarchy

Note that this will return duplicate slot names if inherited slots are
obscured.

=head2 getSlot() - Returns a list of all the slots

=head2 getSlots() - Returns a list of all the slots

This returns a list of slotnames and their values ready for sending to
C<addSlots>.  It takes the same optional parameter passed to C<slotNames>.

For instance, to add all of the field slots in C<$bar> to C<$foo>:

  $foo->reflect->addSlots($bar->reflect->getSlots('FIELD'));

=head2 promoteParents() - This changes the ordering of the parent slots

This expects a list of parent slot names.  There should be no duplicates and
all of the parent slot names should be already existing parent slots on the
object.  These parent slots will be moved forward in the hierarchy in the order
that they are passed.  Unspecified parent slots will retain their current
positions relative to other unspecified parent slots, but as a group they will
be moved to the end of the hierarchy.

=head2 wrap()

=head2 unwrap()

=head2 delegate()

delegate name => slot
name can be string, regex, or array of same.
slot can be slot name, or object, or 2-element array
with slot name or object and method name.
You can delegate to a parent.

=head2 include() - include a package or external file

You can C<require> an arbitrary file in the namespace of an object
or class without adding to the parents using C<include()> :

  $foo->include( 'xx.pl' );

will include whatever is in xx.pl. Likewise for modules:

  $foo->include( 'MyModule' );

will search along your @INC path for MyModule.pm and include it.

You can specify a second parameter that will be the name of a subroutine
that you can use in your included code to refer to the object into
which the code is being included (as long as you don't change packages in the
included code). The subroutine will be removed after the include, so
don't call it from any subroutines defined in the included code.

If you have the following in 'File.pl':

    sub b {'xxx.b'}

    sub c { return thisObject(); }    # DON'T DO THIS!

    thisObject()->reflect->addSlots(
        'parent*' => 'A',
        d         => 'added.d',
        e         => sub {'xxx.e'},
    );

And you include it using:

    $mirror->include('File.pl', 'thisObject');

Then the addSlots will work fine, but if sub c is called, it won't find
thisObject().

=head1 AUTHOR

Written by Ned Konz, perl@bike-nomad.com
and Toby Everett, teverett@alascom.att.com or toby@everettak.org.
5.005_03 porting by chromatic.

Toby Everett is currently maintaining the package.

=head1 LICENSE

Copyright (c) 2001, 2002 Ned Konz and Toby Everett.
All rights reserved.
This program is free software; you can redistribute it
and/or modify it under the same terms as Perl itself.

=head1 SEE ALSO

L<Class::SelfMethods>

L<Class::Object>

L<Class::Classless>

=cut
