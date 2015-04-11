package Dist::Zilla::Plugin::Fatten;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;

use File::Temp qw(tempfile);
use File::Which;
use IPC::System::Options qw(system);
use List::Util qw(first);

use Moose;
with (
    'Dist::Zilla::Role::FileMunger',
    'Dist::Zilla::Role::FileFinderUser' => {
        default_finders => [':ExecFiles'],
    },
);

# TODO: fatten_path?
has include_script => (is => 'rw');
has exclude_script => (is => 'rw');

use namespace::autoclean;

sub mvp_multivalue_args { qw(include_script exclude_script) }

sub munge_files {
    #use experimental 'smartmatch';

    my $self = shift;

    my @scripts0 = @{ $self->found_files };
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

    $self->munge_file($_) for @scripts;
}

sub munge_file {
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
    $file->content($content);
}

__PACKAGE__->meta->make_immutable;
1;
# ABSTRACT: Fatpack scripts during build using 'fatten'

=for Pod::Coverage .+

=head1 SYNOPSIS

In C<dist.ini> in dist top-level directory:

 [Fatten]
 ;;; the default is to include all scripts, but use below to include only some
 ;;; scripts
 ;include_script=bin/script1
 ;include_script=bin/script2

In C<fatten.conf> in dist top-level directory, put your L<fatten> configuration.

During build, your scripts will be replaced with the fatpacked version.


=head1 DESCRIPTION

This plugin will replace your scripts with the fatpacked version. Fatpacking
will be done using L<fatten>.

If C<fatten.conf> exists in your dist's top-level directory, it will be used as
the fatten configuration.


=head1 CONFIGURATION

=head2 include_script = str+

Explicitly include only specified script. Can be specified multiple times. The
default, when no C<include_script> configuration is specified, is to include all
scripts in the distribution.

=head2 exclude_script = str+

Exclude a script. Can be specified multiple times.


=head1 SEE ALSO

L<fatten>
