package CPAN::Processor::CPANMini;

# This is a private instantiable version of CPAN::Mini, for use
# until CPAN::Mini itself catches up to our changes.

our $VERSION = '0.25';

use strict;

use Carp;

use File::Path qw(mkpath);
use File::Basename qw(basename dirname);
use File::Spec::Functions qw(catfile canonpath);
use File::Find qw(find);

use URI ();
use LWP::Simple qw(mirror RC_OK RC_NOT_MODIFIED);

use Compress::Zlib qw(gzopen $gzerrno);

sub update_mirror {
	my $self = ref($_[0]) ? shift : ref(shift)->new(@_);

	# mirrored tracks the already done, keyed by filename
	# 1 = local-checked, 2 = remote-mirrored
	$self->mirror_indices;

	return unless $self->{force} or $self->{changes_made};

	# now walk the packages list
	my $details = catfile($self->{local}, qw(modules 02packages.details.txt.gz));
	my $gz = gzopen($details, "rb") or die "Cannot open details: $gzerrno";
	my $inheader = 1;
	while ($gz->gzreadline($_) > 0) {
		if ($inheader) {
			$inheader = 0 unless /\S/;
			next;
		}

		my ($module, $version, $path) = split;
		next if $self->_filter_module({
			module  => $module,
			version => $version,
			path    => $path,
		});

		$self->mirror_file("authors/id/$path", 1);
	}

	# eliminate files we don't need
	$self->clean_unmirrored;
	return $self->{changes_made};
}

sub new {
	my $class = shift;

	# Create the object, applying defaults
	my %defaults = (changes_made => 0, dirmode => 0711, mirrored => {});
	my $self   = bless { %defaults, @_ } => $class;

	# Check the configuration
	Carp::croak "no local mirror supplied"            unless    $self->{local};
	Carp::croak "no write permission to local mirror" unless -w $self->{local};
	Carp::croak "no remote mirror supplied"           unless    $self->{remote};
	unless ( LWP::Simple::head($self->{remote}) ) {
		Carp::croak "unable to contact the remove mirror";
	}

	$self;
}

sub mirror_indices {
	my $self = shift;

	$self->mirror_file($_) for qw(
	                              authors/01mailrc.txt.gz
	                              modules/02packages.details.txt.gz
	                              modules/03modlist.data.gz
	                             );
}

sub mirror_file {
	my $self   = shift;
	my $path   = shift;           # partial URL
	my $skip_if_present = shift;  # true/false

	my $remote_uri = URI->new_abs($path, $self->{remote})->as_string; # full URL
	my $local_file = catfile($self->{local}, split "/", $path); # native absolute file
	my $checksum_might_be_up_to_date = 1;

	if ($skip_if_present and -f $local_file) {
		## upgrade to checked if not already
		$self->{mirrored}{$local_file} = 1 unless $self->{mirrored}{$local_file};
	} elsif (($self->{mirrored}{$local_file} || 0) < 2) {
		## upgrade to full mirror
		$self->{mirrored}{$local_file} = 2;

		mkpath(dirname($local_file), $self->{trace}, $self->{dirmode});
		$self->trace($path);
		my $status = mirror($remote_uri, $local_file);

		if ($status == RC_OK) {
			$checksum_might_be_up_to_date = 0;
			$self->trace(" ... updated\n");
			$self->{changes_made}++;
		} elsif ($status != RC_NOT_MODIFIED) {
			warn "\n$remote_uri: $status\n";
			return;
		} else {
			$self->trace(" ... up to date\n");
		}
	}

	if ($path =~ m{^authors/id}) { # maybe fetch CHECKSUMS
		my $checksum_path =
			URI->new_abs("CHECKSUMS", $remote_uri)->rel($self->{remote});
		if ($path ne $checksum_path) {
			$self->mirror_file($checksum_path, $checksum_might_be_up_to_date);
		}
	}
}

sub _filter_module {
	my $self = shift;
	my $args = shift;
 
	if($self->{skip_perl}) {
		return 1 if $args->{path} =~ m{/(?:emb|syb|bio)*perl-\d}i;
		return 1 if $args->{path} =~ m{/(?:parrot|ponie)-\d}i;
		return 1 if $args->{path} =~ m{/\bperl5\.0}i;
	}

	if ($self->{path_filters}) {
		if (ref $self->{path_filters} && ref $self->{path_filters} eq 'ARRAY') {
			foreach my $filter (@{ $self->{path_filters} }) {
				return 1 if $args->{path} =~ $filter;
			}
		} else {
			return 1 if $args->{path} =~ $self->{path_filters};
		}
	}

	if ($self->{module_filters}) {
		if (ref $self->{module_filters} && ref $self->{module_filters} eq 'ARRAY') {
			foreach my $filter (@{ $self->{module_filters} }) {
				return 1 if $args->{module} =~ $filter;
			}
		} else {
			return 1 if $args->{module} =~ $self->{module_filters};
		}
	}

	return 0;
}

sub file_allowed {
	my ($self, $file) = @_;
	return if $self->{exact_mirror};
	return (substr(basename($file),0,1) eq '.') ? 1 : 0;
}

sub clean_unmirrored {
	my $self = shift;

	find sub {
		my $file = canonpath($File::Find::name);
		return unless (-f $file and not $self->{mirrored}{$file});
		return if $self->file_allowed($file);
		$self->trace($file);
		$self->clean_file($file);
		$self->trace(" ... removed\n");
	}, $self->{local};
}

sub clean_file {
	my ($self, $file) = @_;
	unlink $file or warn "Cannot remove $file $!";
}

sub trace {
	my ($self, $message, $force) = @_;
	print "$message" if $self->{trace} or $force;
}

1;
