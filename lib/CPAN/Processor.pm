package CPAN::Processor;

=pod

=head1 NAME

CPAN::Processor - Use PPI to process every perl file/module in CPAN

=head1 DESCRIPTION

CPAN::Processor implements a system for processing every perl file in CPAN.

Under the covers, it subclasses CPAN::Mini to fetch and update all significant
files in CPAN and PPI::Processor to do the actual processing.

=head2 How does it work

CPAN::Processor starts with a CPAN::Mini local mirror, which it will
generally update before each run. Once the CPAN::Mini directory is current,
it will extract all of the perl files to a processor working directory.

A PPI::Processor is then started and run against all of the perl files
contained in the working directory.

=head1 STATUS

Although this module is largely complete, it is broken pending upgrades to
CPAN::Mini to support instantiability.

=head1 METHODS

=cut

use strict;
use UNIVERSAL 'isa';
use base 'CPAN::Processor::CPANMini';
use File::Remove   ();
use IO::Zlib       (); # Will be needed by Archive::Tar
use Archive::Tar   ();
use PPI::Processor ();

use vars qw{$VERSION $errstr};
BEGIN {
	$VERSION = '0.01';
	$errstr  = '';
}





#####################################################################
# Constructor and Accessors

=pod

=head2 new

The C<new> constructor is used to create and configure a new CPAN
Processor. It takes a set of named params something like the following.

  # Create a CPAN processor
  my $Object = CPAN::Processor->new(
  	# The normal CPAN::Mini params
  	local     => '...',
  	remote    => '...',
 
 	# Additional params
  	processor => $Processor, # A new PPI::Processor object
  	);

=over

=item minicpan args

CPAN::Processor inherits from L<CPAN::Mini>, so all of the arguments that
can be used with CPAN::Mini will also work with CPAN::Processor.

Please note that CPAN::Processor applies some additional defaults,
turning skip_perl on.

=item processor

A PPI Processor engine is used to do the actual processing of the perl
files once they have been updated and unpacked.

The processor param should consist of a created and fully configured
L<PPI::Proccessor> object. The CPAN::Processor will call it's ->run
method at the appropriate time.

=item file_filters

CPAN::Processor adds an additional type of filter to the standard ones.

Although by default CPAN::Processor only extract files of type .pm, .t and
.pl from the archives, you can add a list of additional things you do not
want to be extracted.

  file_filters => [
    qr/\binc\b/i, # Don't extract included modules
    qr/\bAcme\b/, # Don't extract anything related to Acme
  ]

=back

Returns a new CPAN::Processor object, or C<undef> on error.

=cut

sub new {
	my $class = ref $_[0] ? ref shift : shift;
	my %args  = @_;
	$class->_clear;

	# Check the main params
	my $Processor = delete $args{processor};
	unless ( isa(ref $Processor, 'PPI::Processor') ) {
		return $class->_error("'processor' param missing or not a PPI::Processor object"); 
	}
	unless ( -w $Processor->source ) {
		return $class->_error("Processor source directory is not writable");
	}

	# Call up to get the base object
	my $self = eval { $class->SUPER::new( %args ) };
	if ( $@ ) {
		my $message = $@;
		$message =~ s/\bat line\b.+//;
		return $class->_error($message);
	}

	# Compile file_filters if needed
	$self->_compile_filter('file_filters') or return undef;

	# Add the additional properties
	$self->{processor} = $Processor;

	$self;
}

=pod

=head2 processor

The C<processor> accessor return the L<PPI::Processor> object the
CPAN::Processor was created with.

=cut

sub processor { $_[0]->{processor} }





#####################################################################
# Main Methods

=pod

=head2 run

The C<run> methods starts the main process, updating the minicpan mirror
and extracted version, and then launching the PPI Processor to process the
files in the source directory.

=cut

sub run {
	my $self = shift;

	# Prepare to start
	$self->_clear;
	$self->{added}   = {};
	$self->{cleaned} = {};

	# Update the CPAN::Mini local mirror
	my $changes = $self->update_mirror;
	return '' unless $changes;

	# Launch the processor
	$self->processor->run;
}





#####################################################################
# CPAN::Mini Methods

# Track what we have added
sub mirror_file {
	my ($self, $file) = @_;
	my $rv = $self->SUPER::mirror_file($file);

	# Extract the new file to the matching directory in
	# the processor source directory.
	my $local_tar = File::Spec->catfile( $self->{local}, $file );
	my @contents  = Archive::Tar->list_archive( $local_tar );

	# Filter to get just the ones we want
	@contents = grep { /\.(?:pm|pl|t)$/ } @contents;
	if ( $self->{file_filters} ) {
		@contents = grep &{$self->{file_filters}}, @contents;
	}
	if ( @contents ) {
		my $files = scalar @contents;
		$self->trace(" ... $files file(s) to process\n");

		# Extract the needed files
		my $Tar = Archive::Tar->read( $local_tar )
			or die('Failed to create Archive::Tar object');
		foreach my $wanted ( @contents ) {
			my $source_file = File::Spec->catfile(
				$self->processor->source, $file, $wanted,
				);
			$self->trace("        extracting $wanted");
			$Tar->extract_file( $wanted, $source_file )
				or die('Failed to extract $wanted');
			$self->trace(" ... extracted\n");
		}

		$Tar->clear;
		$self->trace("        All files to process extracted");
	}

	$self->{added}->{$file} = 1;
	$rv;
}

# Also remove any processing directory.
# And track what we have removed.
sub clean_file {
	my ($self, $file) = @_;

	# Remove the source directory, if it exists
	my $source_path = File::Spec->catfile( $self->processor->source, $file );
	if ( -e $source_path ) {
		if ( File::Remove::remove( \1, $source_path ) ) {
			$self->trace(' ... removed processing files');
		} else {
			warn "Cannot remove $source_path $!";
		}
	}

	# We are doing this in the reverse order to when we created it.
	my $rv = $self->SUPER::clean_file($file);

	$self->{cleaned}->{$file} = 1;
	$rv;
}

# Don't let ourself be forced into printing something
sub trace {
	my ($self, $message) = @_;
	print "$message" if $self->{trace};
}





#####################################################################
# Support Methods and Error Handling

# Compile a set of file filters
sub _compile_filter {
	my $self = shift;
	my $name = shift;

	# Handle some common shortcut cases
	return 1 unless $self->{$name};
	unless ( ref $self->{$name} eq 'ARRAY' ) {
		return $self->_error("$name is not an ARRAY reference");
	}
	unless ( @{$self->{$name}} ) {
		delete $self->{file_filters};
		return 1;
	}

	# Build the anonymous sub
	my @filters = @{$self->{$name}};
	$self->{$name} = sub {
		foreach my $regex ( @filters ) {
			return '' if $_ =~ $regex;
		}
		return 1;
		};

	1;
}

# Set the error message
sub _error {
	$errstr = $_[1];
	undef;
}

=pod

=head2 errstr

When an error occurs, the C<errstr> method can be used to get access to
the error message.

Returns a string containing the error message, or the null string '' if
there was no error in the last call.

=cut

# Fetch the error message
sub errstr {
	$errstr;
}

# Clear the error message
sub _clear {
	$errstr = '';
}

1;

=pod

=head1 SUPPORT

Bugs should always be submitted via the CPAN bug tracker

L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=CPAN%3A%3AProcessor>

For other issues, contact the maintainer

=head1 AUTHOR

Adam Kennedy (Maintainer), L<http://ali.as/>, cpan@ali.as

Funding provided by The Perl Foundation

=head1 COPYRIGHT

Copyright (c) 2004 Adam Kennedy. All rights reserved.
This program is free software; you can redistribute
it and/or modify it under the same terms as Perl itself.

The full text of the license can be found in the
LICENSE file included with this module.

=head1 SEE ALSO

L<PPI::Processor>, L<PPI>, L<CPAN::Mini>, L<File::Find::Rule>

=cut
