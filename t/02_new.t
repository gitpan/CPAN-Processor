#!/usr/bin/perl -w

# Test the constructor

use strict;
use lib ();
use UNIVERSAL 'isa';
use File::Spec::Functions ':ALL';
BEGIN {
	$| = 1;
	unless ( $ENV{HARNESS_ACTIVE} ) {
		require FindBin;
		chdir ($FindBin::Bin = $FindBin::Bin); # Avoid a warning
		lib->import( catdir( updir(), updir(), 'modules') );
	}
}

use Test::More tests => 17;

use File::Remove    ();
use PPI::Processor  ();
use CPAN::Processor ();

# Create the test directories
ok( mkdir('source'),   'Created testing source directory' );
ok( mkdir('minicpan'), 'Created testing minicpan local mirror' );
END {
	File::Remove::remove( \1, 'source' )   if -e 'source';
	File::Remove::remove( \1, 'minicpan' ) if -e 'minicpan';
}

# Create a null test processor
my $Processor = PPI::Processor->new(
	source => 'source',
	);
isa_ok( $Processor, 'PPI::Processor' );
ok( $Processor->add_task('PPI::Processor::Task'), 'Added null task' );

# Create the test object
my $Object = CPAN::Processor->new(
	local     => 'minicpan',
	remote    => 'http://cpan.org/',
	processor => $Processor,
	);
is( CPAN::Processor->errstr, '', '->errstr is false after object creation' );
isa_ok( $Object, 'CPAN::Processor' );
isa_ok( $Object->processor, 'PPI::Processor' );
is( $Object->processor->source, 'source', 'Checked source value' );
is( CPAN::Processor->errstr, '', '->errstr is false' );

# Check error handling
is( CPAN::Processor->_error('foo'), undef, '->_error returns false' );
is( CPAN::Processor->errstr, 'foo', '->_error sets error string' );

# Check _compile_filter
is( $Object->_compile_filter('foo'), 1, '->_compile_filter returns true for non-existant property' );
is( $Object->_compile_filter('file_filters'), 1, '->_compile_filter returns true for empty file_filters' );
$Object->{file_filters} = [ qr/foo/, qr/bar/ ];
is( $Object->_compile_filter('file_filters'), 1, '->_compile_filter returns true for valid file_filters' );
ok( $Object->{file_filters}, 'file_filters is true' );
is( ref($Object->{file_filters}), 'CODE', 'file_filters is a code ref' );
my @start  = qw{foo bar thisfoo this that};
my @finish = grep &{$Object->{file_filters}}, @start;
is_deeply( \@finish, [ 'this', 'that' ], 'Compiled file_filters works as expected' );

exit();
