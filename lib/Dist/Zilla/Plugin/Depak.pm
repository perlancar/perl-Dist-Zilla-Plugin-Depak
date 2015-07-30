package Dist::Zilla::Plugin::Depak;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;

use App::lcpan::Call qw(call_lcpan_script);
use Data::Dmp;
use Dist::Zilla::File::InMemory;
use File::Path qw(make_path);
use File::Slurper qw(read_binary write_binary);
use File::Temp qw(tempfile tempdir);
use File::Which;
use IPC::System::Options qw(system);
use JSON;
use List::Util qw(first);

use Moose;
with (
    'Dist::Zilla::Role::FileFinderUser' => {
        default_finders => [':ExecFiles', ':InstallModules'],
    },
    'Dist::Zilla::Role::FileGatherer',
    'Dist::Zilla::Role::FileMunger',
    'Dist::Zilla::Role::PERLANCAR::WriteModules',
);

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

    $self->log_fatal(["Can't find depak in PATH"]) unless which("depak");

    # we use the depak CLI instead of App::depak because we want to use
    # --config-profile.
    my $profile = $file->name;
    $profile =~ s!.+[\\/]!!;

    # since we're dealing with CLI, we need actual files. even a modified
    # DZF:OnDisk might not have the actual file located in $file->name, so we
    # write to tempfile first.

    my $source;
    {
        my ($fh, $filename) = tempfile();
        $source = $filename;
        write_binary($filename, $file->content);
    }

    my $target;
    {
        my ($fh, $filename) = tempfile();
        $target = $filename;
    }

    $self->write_modules_to_dir;
    my $mods_tempdir = $self->written_modules_dir;

    # the --json output is so that we can read the list of included modules
    my @depak_cmd = (
        "depak",
        "--include-dir", $mods_tempdir,
        "-i", $source, "-o", $target, "--overwrite",
        "--json",
    );

    if (-f "depak.conf") {
        push @depak_cmd, (
            "--config-profile", $profile,
            "--config-path", "depak.conf",
        );
    }

    $self->log_debug(["Depak-ing %s: %s", $file->{name}, \@depak_cmd]);
    my $stdout;
    system({die=>1, log=>1, shell=>0, capture_stdout=>\$stdout}, @depak_cmd);

    my $depak_res = JSON::decode_json($stdout);
    $self->log_fatal(["depak failed: %s", $depak_res])
        unless $depak_res->[0] == 200;

    my $content = read_binary($target);

    $self->log_debug(["depak output: %s (%s, %d bytes)",
                      $file->{name}, $target, length($content)]);

    #$self->log_debug(["depak result: %s", $depak_res]);

    for (@{ $depak_res->[3]{'func.included_modules'} }) {
        $self->{_mods}{$_} = 0;
    }

    # re-add the file instead of changing the content, so we can re-set the
    # encoding to 'bytes'
    my $newfile = Dist::Zilla::File::InMemory->new(
        encoding=>'bytes', name=>$file->{name}, content => $content);
    $self->zilla->prune_file($file);
    $self->add_file($newfile);
}

sub munge_module {
    my ($self, $file) = @_;

    my $munged;
    my $content = $file->content;
    my @pod;

    if ($content =~ /^#\s*(PACKED_MODULES|PACKED_CONTENTS_POD)\s*$/m) {
        $munged++;
        $self->{_mods} //= {};
        $content =~ s/(^#\s*PACKED_MODULES\s*$)/
            "our \@PACKED_MODULES = \@{" . dmp([sort keys %{$self->{_mods}}]) . "}; $1"/em;
        push @pod, "Modules packed into this distribution:\n\n=over\n\n",
            (map {"=item * $_\n\n"} sort keys %{$self->{_mods}}),
            "\n=back\n\n";
    }

    if ($content =~ /^#\s*(PACKED_DISTS|PACKED_CONTENTS_POD)\s*$/m) {
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
        $content =~ s/(^#\s*PACKED_DISTS\s*$)/
            "our \@PACKED_DISTS = \@{" . dmp([sort keys %{$self->{_dists}}]) . "}; $1"/em;
        push @pod, "Distributions packed into this distribution:\n\n=over\n\n",
            (map {"=item * $_\n\n"} sort keys %{$self->{_dists}}),
            "\n=back\n\n";
    }

    if ($content =~ /^#\s*PACKED_CONTENTS_POD\s*$/m) {
        $munged++;
        $content =~ s/(^#\s*PACKED_CONTENTS_POD\s*$)/
            join("", @pod)/em;
        push @pod, "Distributions packed inside this script:\n\n=over\n\n",
            (map {"=item * $_\n\n"} sort keys %{$self->{_dists}}),
            "\n=back\n\n";
    }

    if ($munged) {
        $self->log_debug(["Setting \@PACKED_MODULES / \@PACKED_DISTS / PACKED_CONTENTS_POD in %s", $file->{name}]);
        $file->content($content);
    }
}

sub gather_files {}

__PACKAGE__->meta->make_immutable;
1;
# ABSTRACT: Pack dependencies onto scripts during build using 'depak'

=for Pod::Coverage .+

=head1 SYNOPSIS

In F<dist.ini>:

 [Depak]
 ;;; the default is to include all scripts, but use below to include only some
 ;;; scripts
 ;include_script=bin/script1
 ;include_script=bin/script2

In C<depak.conf> in dist top-level directory, put your L<depak> configuration.

During build, your scripts will be replaced with the packed version.

Also, you should also have a module named C<Something::Packed> (i.e. whose name
ends in C<::Packed>), which contains:

 # PACKED_MODULES
 # PACKED_DISTS

During build, these will be replaced with:

 our @PACKED_MODULES = (...); # PACKED_MODULES
 our @PACKED_DISTS = (...); # PACKED_DISTS


=head1 DESCRIPTION

This plugin will replace your scripts with the packed version (that is, scripts
that have their dependencies packed onto themselves). Packing will be done using
L<depak>.

If F<depak.conf> exists in your dist's top-level directory, it will be used as
the depak configuration.

In addition to replacing scripts with the packed version, it will also search
for directives C<# PACKED_MODULES> and C<# PACKED_DISTS> in module files and
replace them with C<@PACKED_MODULES> and C<@PACKED_DISTS>. The
C<@PACKED_MODULES> array lists all the modules that are included in the one of
the scripts. This can be useful for tools that might need it. C<@PACKED_DISTS>
array lists all the dists that are included in one of the scripts. This also can
be useful for tools that might need it, like
L<Dist::Zilla::Plugin::PERLANCAR::CheckDepDists>.

There is also C<# PACKED_CONTENTS_POD> which you can put in your script. It will
be replaced with POD that list the packed modules/dists.


=head1 CONFIGURATION

=head2 include_script = str+

Explicitly include only specified script. Can be specified multiple times. The
default, when no C<include_script> configuration is specified, is to include all
scripts in the distribution.

=head2 exclude_script = str+

Exclude a script. Can be specified multiple times.


=head1 SEE ALSO

L<depak>
