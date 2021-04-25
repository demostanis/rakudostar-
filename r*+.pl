#!/usr/bin/env perl

use strict;
use warnings;
no strict 'vars';
no warnings 'once';
use experimental 'switch';
use Parallel::ForkManager;
use LWP::UserAgent ();
use IPC::Run qw(run);
use GnuPG::Interface;
use Archive::Tar;
use Getopt::Std;
use Time::Duration;
use File::Copy;
use File::Path;
use Try::Tiny;
use Git;

# TODO: Long options?
# help, silent, interactive, modules, MoarVM, NQP, Rakudo, workdir, yes, git, prefix, GPG key, pass GPG, max jobs, run tests
getopts('hsimMNRw:ygp:G:Pj:t');

if($opt_h) {
	print <<EOH;
Rakudo Star+
A tool to easily install a Rakudo distribution

$0 [OPTIONS...] where OPTIONS is none, one or a combination of:
	-h       -- Shows this help.
	-s       -- Hides some ran commands' output
	-i       -- Interactive mode, asks some questions
	-m       -- Installs only modules
	-M       -- Installs only MoarVM
	-N       -- Installs only NQP
	-R       -- Installs only Rakudo
	-w VALUE -- Specifies the work directory, defaults to .work
	-y       -- Answers YES to all questions
	-g       -- Fetches with git instead of HTTP
	-p VALUE -- Specifies the prefix to install to, defaults to .install
	-G VALUE -- Specifies the GPG key to verify binaries with
	-P       -- Passes the GPG verification
	-j VALUE -- Specifies the maximum parallel jobs to run, defaults to 4
	-t       -- Specifies whether tests should be run

EXAMPLES:
	$0 -Ntgp/usr -- Installs only NQP, runs tests, fetches with git, to /usr
	$0 -iPj32    -- Installs everything, interactively, skips GPG verification, with 32 jobs

Made by demostanis
https://github.com/demostanis/rakudostar+
EOH
	exit 0;
}

my $choice;
my $jobs = $opt_j || 4;
my $start_time = time;
my $workdir = $opt_w || '.work';
mkdir $workdir;
# We check if the path is absolute, if not we prefix it with '../../../' so
# that components get installed in the specified path relative to the current folder.
my $prefix = $opt_p ? index($opt_p, '/') != 0 && '../../../' . $opt_p || $opt_p : '/usr/local';
my $pm = Parallel::ForkManager->new($jobs);
my $gpg = GnuPG::Interface->new;

if($opt_m) {
	$choice = 'modules';
}
if($opt_M) {
	$choice = 'MoarVM';
}
if($opt_N) {
	$choice = 'NQP';
}
if($opt_R) {
	$choice = 'Rakudo';
}

print "Welcome to Rakudo Star+!\n";
if($opt_i) { # Interactive mode
	CHOOSE: while(!$choice) {
		print "Available choices are MoarVM, NQP, Rakudo or everything.\n";
		print "Please choose what to install: ";

		my %available_choices = qw/modules MoarVM NQP Rakudo everything/;
		chomp(my $answer = lc <STDIN>);
		next unless($answer);
		for(%available_choices) {
			# 'modules' has precedence over 'MoarVM',
			# which means that if the user inputs 'm' or 'mo',
			# modules will be installed.
			if(lc =~ /^$answer/) {
				$choice = $_;
				last CHOOSE;
			}
		}
	}
} elsif(!$choice) {
	$choice = 'everything';
}

sub yes {
	return <STDIN> =~ /y+.*/i;
}

sub nope {
	return !yes;
}

my $version = "2021.04";
if(open(my $versionf, '<', 'version')) {
	chomp($version = <$versionf>);
}

open(my $sourcesf, '<', $opt_g ? 'git.sources' : 'sources')
	or die "Couldn't open file 'sources': $!";

# This file takes the following form:
#  <COMPONENT> = <URL>
#  							 <SECOND URL>
#  							 <THIRD URL>
#  							 ...
#	 <OTHER COMPONENTS> = ...
#	 ...
my (%sources, $cur);
while(<$sourcesf>) {
	if(/^(\w+)\s*=\s*(\S+)$/) {
		$cur = $1;
		push @{ $sources{$1} }, $2;
	} elsif(/^\s*(\S+)$/) {
		push @{ $sources{$cur} }, $1;
	}	
}

sub install {
	my ($what, %config) = @_;
	my $folder = $config{folder};
	my @steps = @{$config{run}};

	my $oldworkdir = $workdir;
	$workdir = $workdir . '/' . lc $what;
	mkdir $workdir if !-d $workdir;

	print "Installing $what...\n";
	my ($first_answer, @files);
	my $first_time = 1;
	foreach(@{ $sources{$what} }) {
		my $url = $_ =~ s/%s/$version/gr;
		my ($response, $ua, $type);
		if(!$opt_g) {
			$ua = LWP::UserAgent->new;

			# MoarVM website rejects
			# the default user agent.
			$ua->agent("r*+, I don't mean no harm");
			$ua->show_progress(1);
		}

		my $destfile = $opt_g ? "$workdir/$folder" : "$workdir/archive.tar.gz";

		if($opt_g) {
			$type = 'git';
		} else {
			$type = 'tar';
			if($url =~ /\.asc$/) {
				$destfile .= '.asc';
				$type = 'asc';
			}
		}

		sub fetch {
			my ($url, $destfile, $what, $ua, $response, $first_time, $folder) = @_;
			print "Fetching $what...\n" if $first_time;
			if($opt_g) {
				try {
					rmtree $workdir;
					my $r = Git->repository(Repository => $workdir);
					$r->command("clone", "git://$url", $destfile);
				} catch {
					$response = { succeeded => 0 };
				}
			} else {
				$response = $ua->get("https://$url",
					':content_file' => $destfile);
			}
			return 0;
		}

		# This piece of code is really messy.
		# If a previously downloaded archive is found,
		# we ask the user if wants to keep it (or to download a new one),
		# IF he's in interactive mode and that he didn't choose -y.
		my @fetch_opts = ($url, $destfile, $what, $ua, $response, $first_time, $folder);
		if(-e $destfile) {
			if(!$opt_y && $opt_i) {
				unless(defined $first_answer) {
					print "A previously downloaded archive was found in $workdir.\n";
					print "Do you want to use it to build $what? ";
					if($first_answer = nope) {
						$first_time = fetch @fetch_opts;
					}
				} elsif($first_answer) {
					$first_time = fetch @fetch_opts;
				}
			} elsif(!$opt_y) {
				$first_time = fetch @fetch_opts;
			}
		} else {
			$first_time = fetch @fetch_opts;
		}
		
		push @files, {
			type => $type,
			path => $destfile,
			succeeded => !$response || $response->is_success,
			response => $response
		};
	}

	if(!$opt_g) {
		my ($asc) = grep { $_->{type} eq 'asc' } @files;
		my ($archive) = grep { $_->{type} eq 'tar' } @files;
		if($asc->{succeeded} && $archive->{succeeded}) {
			if(!$opt_P) {
				print "Verifying $what...\n";
				my $error = IO::Handle->new;
				my $handles = GnuPG::Handles->new(stdin => $input,
					stdout => $output, stderr => $error);
				my $pid = $gpg->verify(handles => $handles, command_args => $asc->{path});
				while(<$error>) {
					print;
					# Alexander Kiryuhin <alexander.kiryuhin@gmail.com>
					if($opt_G ? /$opt_G/ : /FE750D152426F3E50953176ADE8F8F5E97A8FCDE/) {
						last;
					} else {
						die <<EOE if eof;
Failed to verify the archive.
Did you pass a bad value to the -G option?
Otherwise, you are fucked.
You can retry (but not advised) with the -P option
to pass the GPG verification step.
EOE
					}
				}

				print "Good signature!\n";
				close $error;
				waitpid $pid, 0;
			}

			print "Unpacking $what...\n";
			STDOUT->flush;
			my $file = Archive::Tar->new($archive->{path}); 
			$file->setcwd("$workdir");
			$file->extract();
		} else {
			my $status = $archive->{response}->status_line;
			my $other_status = $asc->{response}->status_line;
			die <<EOE
Failed to fetch sources for $what. The server returned $status and $other_status.
Perhaps a restrictive firewall? Rate limited? You can also file a bug report at
https://github.com/demostanis/rakudostar+
EOE
		}
	} else {
		my ($git) = grep { $_->{type} eq 'git' } @files;
		if(!$git->{succeeded}) {
			die <<EOE
Failed to fetch sources through git for $what.
Perhaps a restrictive firewall? Rate limited? You can also file a bug report at
https://github.com/demostanis/rakudostar+
EOE
		}
	}
	chdir "$workdir/$folder";
	print "Starting build...\n";
	
	for(@steps) {
		my $cmd = $opt_s ? $_ . ' >/dev/null 2>&1' : $_;
		print "Running $cmd...\n";
		system($cmd);	
		die <<EOE if $?;
Oh no! Installing $what failed with status code $?.
Scroll up for more details.
EOE
	}
	
	chdir "../../..";
	$workdir = $oldworkdir;
}

sub install_moarvm {
	install 'MoarVM', (
		folder => "MoarVM-$version",
		# TODO: Support other backends?
		run => ["perl Configure.pl" . ($prefix ? " --prefix=$prefix" : ''),
						"make install -j$jobs"],
	);
}

sub install_nqp {
	install 'NQP', (
		folder => "nqp-$version",
		run => ["perl Configure.pl --backends=moar" . ($prefix ? " --prefix=$prefix" : ''),
						"make install -j$jobs"],
	);
}

sub install_rakudo {
	install 'Rakudo', (
		folder => "rakudo-$version",
		run => ["perl Configure.pl --backends=moar" . ($prefix ? " --prefix=$prefix" : ''),
						"make install -j$jobs"],
	);
}

sub install_modules {
	open(my $modules, '<', 'modules')
		or die "Couldn't open file 'modules': $!";

	while(<$modules>) {
		chomp;
		if(!/^#/ && m!([0-9A-Za-z\-]+)\s+(\S+)\s*(.+)?!) {
			my ($name, $url, $branch) = ($1, $2, $3, $4);
			$pm->start and next;
			my $oldworkdir = $workdir;
			$workdir = $workdir . '/modules';
			mkdir $workdir if !-d $workdir;
			my $destfile = lc "$workdir/$name";
			rmtree $destfile;

			print "Cloning $url...\n";
			my $r = Git->repository(Repository => $workdir);
			my @args = ("clone", "https://$url", $destfile, '--config', 'advice.detachedHead=false');
			push @args, '-q' if $opt_s;
			push @args, ('-b', $branch) if defined $branch;
			$r->command(@args);

			chdir $destfile;
			my $program = <<EOP;
my \$path = '.'.IO;
my \$repository = CompUnit::RepositoryRegistry.repository-for-name('vendor');
my \$dist = Distribution::Path.new(\$path);
\$repository.install(\$dist, :force);
EOP
			my ($out, $err);
			run ["$prefix/bin/raku"], \$program, \$out, \$err;
			print "Installed $name\n";
			chdir "../../..";

			$workdir = $oldworkdir;
			$pm->finish;
		}
	}

	$pm->wait_all_children;
}

given($choice) {
	when('MoarVM') {
		install_moarvm;
	}
	when('NQP') {
		install_nqp;
	}
	when('Rakudo') {
		install_rakudo;
	}
	when('everything') {
		install_moarvm;
		install_nqp;
		install_rakudo;
		install_modules;
	}
	when('modules') {
		install_modules;
	}
}

my $end_time = time;
my $run_time = duration($end_time - $start_time);
print "Done installing! It took $run_time\n";

# vim:set ts=2 sw=2:
