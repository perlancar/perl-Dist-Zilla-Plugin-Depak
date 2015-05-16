package Dist::Zilla::Plugin::Fatten;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;

use App::lcpan::Call qw(call_lcpan_script);
use Data::Dmp;
use File::Temp qw(tempfile);
use File::Which;
use IPC::System::Options qw(system);
use List::Util qw(first);

use Moose;
with (
    'Dist::Zilla::Role::FileFinderUser' => {
        default_finders => [':ExecFiles', ':InstallModules'],
    },
    'Dist::Zilla::Role::FileMunger',
);

# TODO: fatten_path?
has include_script => (is => 'rw');
has exclude_script => (is => 'rw');

use namespace::autoclean;

sub mvp_multivalue_args { qw(include_script exclude_script) }

sub munge_files {
    #use experimental 'smartmatch';

    my $self = shift;

    my @scripts0 = grep { $_->name =~ m!^(bin|scripts?)! } @{ $self->found_files };
    my @scripts;
    if ($self->include_script) {
        for my $item (@{ $self->include_script }) {
            my $file = first { $item eq $_->name } @scripts0;
            $self->log_fatal(["included '%s' not in list of available scripts", $item])
                unless $file;
            push @scripts, $file;
        }
    } else {
        @scripts = @scripts0;
    }
    if ($self->exclude_script) {
        for my $item (@{ $self->exclude_script }) {
            @scripts = grep { $_->name ne $item } @scripts;
        }
    }
    $self->munge_script($_) for @scripts;

    my @modules  = grep { $_->name =~ m!^(lib)! } @{ $self->found_files };
    $self->munge_module($_) for @modules;
}

sub munge_script {
    my ($self, $file) = @_;

    $self->log_fatal(["Can't find fatten in PATH"]) unless which("fatten");

    my $source;
    if ($file->isa("Dist::Zilla::File::OnDisk")) {
        $source = $file->name;
    } else {
        my ($fh, $filename) = tempfile();
        $source = $filename;
        open $fh, ">", $filename;
        print $fh $file->content;
        close $fh;
    }
    my $target;
    {
        my ($fh, $filename) = tempfile();
        $target = $filename;
    }

    my @fatten_cmd = ("fatten", "-i", $source, "-o", $target, "--overwrite");
    if (-f "fatten.conf") {
        push @fatten_cmd, "--config-path", "fatten.conf";
    }
    $self->log_debug(["Fatpacking %s: %s", $file->{name}, \@fatten_cmd]);
    system({die=>1, log=>1, shell=>0}, @fatten_cmd);

    my $content = do {
        open my($fh), "<", $target or
            $self->log_fatal(["BUG? Can't open fatten output at %s: $!", $target]);
        local $/;
        ~~<$fh>;
    };

    while ($content =~ /^\$fatpacked\{"(.+?)\.pm"\}/mg) {
        my $mod = $1;
        $mod =~ s!/!::!g;
        $self->{_mods}{$mod} = 0;
    }

    $file->content($content);
}

sub munge_module {
    my ($self, $file) = @_;

    my $munged;
    my $content = $file->content;
    if ($content =~ /^#\s*FATTENED_MODULES\s*$/m) {
        $munged++;
        $self->{_mods} //= {};
        $content =~ s/(^#\s*FATTENED_MODULES\s*$)/
            "our \@FATTENED_MODULES = \@{" . dmp(sort keys %{$self->{_mods}}) . "}; $1"/em;
    }

    if ($content =~ /^#\s*FATTENED_DISTS\s*$/m) {
        $munged++;
        unless ($self->{_dists}) {
            if (!keys %{ $self->{_mods} }) {
                $self->{_dists} = {};
            } else {
                my $res = call_lcpan_script(
                    argv => ["mod2dist", keys %{$self->{_mods}}],
                );
                for (values %$res) {
                    $self->{_dists}{$_} = 0;
                }
            }
        }
        $content =~ s/(^#\s*FATTENED_DISTS\s*$)/
            "our \@FATTENED_DISTS = \@{" . dmp(sort keys %{$self->{_dists}}) . "}; $1"/em;
    }

    if ($munged) {
        $file->content($content);
    }
}

__PACKAGE__->meta->make_immutable;
1;
# ABSTRACT: Fatpack scripts during build using 'fatten'

=for Pod::Coverage .+

=head1 SYNOPSIS

In C<dist.ini>:

 [Fatten]
 ;;; the default is to include all scripts, but use below to include only some
 ;;; scripts
 ;include_script=bin/script1
 ;include_script=bin/script2

In C<fatten.conf> in dist top-level directory, put your L<fatten> configuration.

During build, your scripts will be replaced with the fatpacked version.

Also, you should also have a module named C<Something::Fattened> (i.e. whose
name ends in C<::Fattened>), which contains:

 # FATTENED_MODULES
 # FATTENED_DISTS

During build, these will be replaced with:

 our @FATTENED_MODULES = (...); # FATTENED_MODULES
 our @FATTENED_DISTS = (...); # FATTENED_DISTS


=head1 DESCRIPTION

This plugin will replace your scripts with the fatpacked version. Fatpacking
will be done using L<fatten>.

If C<fatten.conf> exists in your dist's top-level directory, it will be used as
the fatten configuration.

In addition to replacing scripts with the fatpacked version, it will also search
for directives C<# FATTENED_MODULES> and C<# FATTENED_DISTS> in module files and
replace them with C<@FATTENED_MODULES> and C<@FATTENED_DISTS>. The
C<@FATTENED_MODULES> array lists all the modules that are included in the one of
the scripts. This can be useful for tools that might need it. C<@FATTENED_DISTS>
array lists all the dists that are included in one of the scripts. This also can
be useful for tools that might need it, like
L<Dist::Zilla::Plugin::PERLANCAR::CheckDepDists>.


=head1 CONFIGURATION

=head2 include_script = str+

Explicitly include only specified script. Can be specified multiple times. The
default, when no C<include_script> configuration is specified, is to include all
scripts in the distribution.

=head2 exclude_script = str+

Exclude a script. Can be specified multiple times.


=head1 SEE ALSO

L<fatten>
