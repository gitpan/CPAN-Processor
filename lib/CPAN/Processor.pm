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

=head1 EXTENDING

This module is relatively stable and complete, but currently uses a
private modified version of CPAN::Mini. Several additional features of
this are yet to be merged back into CPAN::Mini, and so the code and API
are subject to change without notice.

If you wish to write an extension, please stay in contact with the
maintainer while doing so.

=head1 METHODS

=cut

use 5.006;
use strict;
use UNIVERSAL 'isa';
use base 'CPAN::Processor::CPANMini';
use List::Util     ();
use File::Path     ();
use File::Remove   ();
use IO::File       ();
use IO::Zlib       (); # Will be needed by Archive::Tar
use Archive::Tar   ();
use PPI::Processor ();

our $VERSION = '0.07';
our $errstr  = '';





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

=item force_processor

Under normal curcumstances, if there are no changes to the minicpan
mirror, the processor will need to be run. Enabling the C<force_processor>
flag (false by default) will cause the processor to be executed, even if
there are no changes to the minicpan mirror.

=item file_filters

CPAN::Processor adds an additional type of filter to the standard ones.

Although by default CPAN::Processor only extract files of type .pm, .t and
.pl from the archives, you can add a list of additional things you do not
want to be extracted.

  file_filters => [
    qr/\binc\b/i, # Don't extract included modules
    qr/\bAcme\b/, # Don't extract anything related to Acme
  ]

=item check_expand

Once the mirror update has been completed, the check_expand keyword
forces the processor to go back over every tarball in the mirror and
double check that it has a corrosponding expanded directory.

=item archive_tar_report

CPAN::Processor does a lot of work with L<Archive::Tar>, and tends to
encounter a lot of warnings from the various tarballs in CPAN.

If set to a writable filename, a detailed report on the various
warnings encountered during processing will be written to the file you
specify.

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

	# Compile the various reports if needed
	$self->_init_archive_tar_report      or return undef;
	$self->_init_missing_makefile_report or return undef;

	# Add the additional properties
	$self->{processor}       = $Processor;
	$self->{check_expand}    = 1 if $self->{force_expand};
	$self->{force_processor} ||= 0;

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
	my $self = shift->_clear;

	# Prepare to start
	$self->{added}   = {};
	$self->{cleaned} = {};

	# Update the CPAN::Mini local mirror
	$self->trace("Updating MiniCPAN local mirror\n");
	my $changes = eval { $self->update_mirror; };
	$changes ||= 0;
	if ( $@ ) {
		my $message = $@;
		$message =~ s/\bat line\b.+//;
		return $self->_error($message);
	}

	if ( $self->{check_expand} and ! $self->{force} ) {
		# Expansion checking is enabled, and we didn't do a normal
		# forced check, so find the full list of files to check.
		$self->trace("Tarball expansion checking enabled\n");
		my @files = File::Find::Rule->new
		                            ->file
		                            ->name('*.tar.gz')
		                            ->relative
		                            ->in( $self->{local} );

		# Filter to just those we need to expand
		$self->trace("Checking " . scalar(@files) . " tarballs\n");
		@files = grep { ! -d File::Spec->catfile( $self->processor->source, $_ ) } @files;
		if ( @files ) {
			$self->trace("Scheduling " . scalar(@files) . " tarballs for expansion\n");
		} else {
			$self->trace("No tarballs need to be expanded");
		}

		# Expand each of the tarballs
		foreach my $file ( sort @files ) {
			$self->mirror_expand( $file );
			$changes++;
		}
	}

	# Release the warning report file if needed
	if ( $self->{archive_tar_handle} ) {
		$self->{archive_tar_handle}->close;
		delete $self->{archive_tar_handle};
	}
	if ( $self->{missing_makefile_handle} ) {
		$self->{missing_makefile_handle}->close;
		delete $self->{missing_makefile_handle};
	}

	# Return now if no changes
	unless ( $changes or $self->{force_processor} ) {
		return 1;
	}

	# Launch the processor
	$self->trace("Starting PPI::Processor...\n");
	$self->processor->run;
}






#####################################################################
# CPAN::Mini Methods

# If doing forced expansion, remove the old expanded files
# before beginning the mirror update so we don't have to redelete
# and create the ones we do during the update.
sub update_mirror {
	my $self = shift;

	# If we want to force re-expansion,
	# remove all current expansion dirs.
	if ( $self->{force_expand} ) {
		$self->trace("Flushing all expansion directories (flush_expand enabled)\n");
		my $authors_dir = File::Spec->catfile( $self->processor->source, 'authors' );
		if ( -e $authors_dir ) {
			$self->trace("Removing $authors_dir");
			File::Remove::remove( \1, $authors_dir )
				or die "Failed to remove previous expansion directory '$authors_dir'";
			$self->trace(" ... removed\n");
		}
	}

	$self->SUPER::update_mirror(@_);
}

# Track what we have added
sub mirror_file {
	my ($self, $file) = (shift, shift);

	# Do the normal stuff
	my $rv = $self->SUPER::mirror_file($file, @_);

	# Expand the tarball if needed
	unless ( -d File::Spec->catfile( $self->processor->source, $file ) ) {
		$self->{current_file} = $file;
		$self->mirror_expand( $file ) or return undef;
		delete $self->{current_file};
	}

	$self->{added}->{$file} = 1;
	delete $self->{current_file};
	$rv;
}

sub mirror_expand {
	my ($self, $file) = @_;

	# Don't try to expand anything other than tarballs
	return 1 unless $file =~ /\.tar\.gz$/;

	# Extract the new file to the matching directory in
	# the processor source directory.
	my $local_tar = File::Spec->catfile( $self->{local}, $file );
	my @contents;
	{
		local $SIG{__WARN__} = $self->{warn_hook};
		@contents = eval {
			Archive::Tar->list_archive( $local_tar );
			};
	}
	return $self->_tar_error if ( $@ or ! @contents );

	# Run the optional "Missing Makefile.PL" report (ignoring return value)
	$self->_missing_makefile_report( $file, \@contents );

	# Filter to get just the ones we want
	@contents = grep { /\.(?:pm|pl|t)$/ } @contents;
	if ( $self->{file_filters} ) {
		@contents = grep &{$self->{file_filters}}, @contents;
	}
	if ( @contents ) {
		my $files = scalar @contents;

		# Extract the needed files
		my $Tar;
		{
			local $SIG{__WARN__} = $self->{warn_hook};
			$Tar = eval {
				Archive::Tar->new( $local_tar );
				};
		}
		return $self->_tar_error() if ( $@ or ! $Tar );

		# Iterate and extract each file
		foreach my $wanted ( @contents ) {
			my $source_file = File::Spec->catfile(
				$self->processor->source, $file, $wanted,
				);
			$self->trace("    $wanted");

			my $rv;
			{
				local $SIG{__WARN__} = $self->{warn_hook};
				$rv = eval {
					$Tar->extract_file( $wanted, $source_file );
					};
			}
			if ( $@ or ! $rv ) {
				# There was an error during the extraction
				$self->_tar_error( " ... failed" );
				if ( -e $source_file ) {
					# Remove any partial file left behind
					chmod 0644, $source_file;
					File::Remove::remove( $source_file );
				}
				return 1;
			}

			# Extraction successful
			$self->trace(" ... extracted\n");
			chmod 0644, $source_file;
		}

		$Tar->clear;
	} else {
		# Create an empty directory so it isn't checked over and over
		my $source_dir = File::Spec->catfile( $self->processor->source, $file );
		File::Path::mkpath( $source_dir, $self->{trace}, $self->{dirmode} );
	}

	1;
}

# Also remove any processing directory.
# And track what we have removed.
sub clean_file {
	my ($self, $file) = (shift, shift);

	# Clean the expansion directory
	$self->clean_expand( $file );

	# We are doing this in the reverse order to when we created it.
	my $rv = $self->SUPER::clean_file($file, @_);

	$self->{cleaned}->{$file} = 1;
	$rv;
}

# Remove a processing directory
sub clean_expand {
	my ($self, $file) = @_;

	# Remove the source directory, if it exists
	my $source_path = File::Spec->catfile( $self->processor->source, $file );
	if ( -e $source_path ) {
		File::Remove::remove( \1, $source_path )
			or warn "Cannot remove $source_path $!";
	}

	1;	
}

# Don't let ourself be forced into printing something
sub trace {
	my ($self, $message) = @_;
	print "$message" if $self->{trace};
}





#####################################################################
# Support Methods and Error Handling

# Compile a set of filters
sub _compile_filter {
	my $self = shift;
	my $name = shift;

	# Shortcut for "no filters"
	return 1 unless $self->{$name};

	# Allow a single Regexp object for the filter
	if ( isa(ref $self->{$name}, 'Regexp') ) {
		$self->{$name} = [ $self->{$name} ];
	}

	# Check for bad cases
	unless ( ref $self->{$name} eq 'ARRAY' ) {
		return $self->_error("$name is not an ARRAY reference");
	}
	unless ( @{$self->{$name}} ) {
		delete $self->{file_filters};
		return 1;
	}

	# Check we only got Regexp objects
	my @filters = @{$self->{$name}};
	if ( scalar grep { ! isa(ref $_, 'Regexp') } @filters ) {
		return $self->_error("$name can only contains Regexp filters");
	}

	# Build the anonymous sub
	$self->{$name} = sub {
			foreach my $regexp ( @filters ) {
				return '' if $_ =~ $regexp;
			}
			1;
		};

	1;
}

# Compile the optional Archive::Tar report function, if needed
sub _init_archive_tar_report {
	my $self = shift;

	# Shortcut if nothing set
	unless ( $self->{archive_tar_report} ) {
		$self->{warn_hook} = sub { die "Archive::Tar warning" };
		return 1;
	}

	# We have a file, get a handle to it
	my $fh = IO::File->new;
	unless ( defined $fh->open( $self->{archive_tar_report}, '>' ) ) {
		return $self->_error( "Failed to open archive_tar_report '$self->{archive_tar_report}'" )
	}
	$self->{archive_tar_handle} = $fh;

	# Set the larger reporter function
	$self->{warn_hook} = sub {
		if ( $self->{archive_tar_handle} ) {
			my $message = shift;
			$message =~ s~\s+at CPAN/modules/CPAN/Processor\.pm.*~~;
			$self->{archive_tar_handle}->print( "$self->{current_file}\n" );
			$self->{archive_tar_handle}->print( "$message\n" );
		}
		die "Archive::Tar warning";
		};

	# Write the header for the report
	$self->trace("Generating Archive::Tar Report (archive_tar_report provided)\n");
	my $t = scalar localtime time;
	$fh->print("Archive::Tar Warnings and Errors Report\n");
	$fh->print("(Generated by CPAN::Processor $VERSION at $t)\n");
	$fh->print("\n");
	$fh->print("This report outlines all .tar.gz files found in CPAN that\n");
	$fh->print("generated either a die or warn during ->list_archive( tarfile ) ,\n");
	$fh->print("->new( tarfile ), or \$Tar->extract_file( file, destination )\n");
	$fh->print("----------------------------------------------------------------\n");
	$fh->print("\n");

	1;
}

# Load a handle for a report
sub _init_missing_makefile_report {
	my $self = shift;
	return 1 unless $self->{missing_makefile_report};

	# We have a file, get a handle to it
	my $fh = IO::File->new;
	unless ( defined $fh->open( $self->{missing_makefile_report}, '>' ) ) {
		return $self->_error( "Failed to open missing_makefile_report '$self->{missing_makefile_report}'" )
	}
	$self->{missing_makefile_handle} = $fh;

	# Write the header for the report
	$self->trace("Generating Missing Makefile.PL Report (missing_makefile_report provided)\n");
	my $t = scalar localtime time;
	$fh->print("Report: Has Build.PL without a Makefile.PL\n");
	$fh->print("(Generated by CPAN::Processor $VERSION at $t)\n");
	$fh->print("\n");
	$fh->print("This report outlines all .tar.gz files found in CPAN that\n");
	$fh->print("had a new-style Build.PL but did not have an Makefile.PL,\n");
	$fh->print("which is needed for compatibility with older CPAN.pm versions\n");
	$fh->print("----------------------------------------------------------------\n");
	$fh->print("\n");

	1;
}

sub _missing_makefile_report {
	my ($self, $file, $contents) = @_;
	return 1 unless $self->{missing_makefile_handle};

	# Skip if the tarball does not have a Build.PL
	return 1 unless List::Util::first { /\bBuild.PL$/i } @$contents;

	# Does it have a Makefile.PL?
	return 1 if List::Util::first { /\bMakefile.PL$/i } @$contents;

	# Has Build.PL, but not Makefile.PL
	$self->{missing_makefile_handle}->print( "$self->{current_file}\n" );

	1;
}

# Set the error message
sub _error {
	$errstr = $_[1];
	undef;
}

sub _tar_error {
	my $self    = shift;

	# Get and clean up the message
	my $message = shift || "Expansion of $self->{current_file} failed";
	$message .= " (Archive::Tar warning)" if $@ =~ /Archive::Tar warning/;
	$message .= "\n";

	$self->trace( $message );
	1;	
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

# Clear the error message.
# Returns the object/class as a convenience
sub _clear {
	$errstr = '';
	$_[0];
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
