use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
  'NAME'    => 'Class::Prototyped',
  'VERSION_FROM'  => 'Class/Prototyped.pm', # finds $VERSION
  'PREREQ_PM'    => {
    'Carp' => undef,
    'Test' => undef,      # for testing
    'Data::Dumper' => undef,  # for testing
  }, # e.g., Module::Name => 1.1
  PM => {
    'Class/Prototyped.pm' => '$(INST_LIBDIR)/Prototyped.pm',
    'Class/Prototyped/Graph.pm' => '$(INST_LIBDIR)/Prototyped/Graph.pm',
  },
);
