#!/usr/bin/env perl
# Private selection and memory-estimate mechanics for fm-lint.sh, which owns
# the canonical inventory, public modes, analysis flags, and scheduling policy.
# No shell code is evaluated. Source-line filename references include fixture
# snippets, so selection can over-include but does not depend on execution.
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);

my ($mode, $argument, @roots) = @ARGV;
sub git_output {
    open my $pipe, '-|', 'git', @_ or die "git: $!\n";
    local $/;
    my $out = <$pipe> // '';
    close $pipe or die "git failed: @_\n";
    return $out;
}
my %measurements;
if ($mode eq 'weights' && open my $file, '<', $argument) {
    my $header = <$file> // '';
    my $version = $ENV{FM_LINT_PLAN_VERSION} // '';
    while (<$file>) {
        next unless $version ne '' && $header eq "# ShellCheck $version\n";
        chomp;
        my ($path, $digest, $rss) = split /\t/;
        next unless defined($rss) && $digest =~ /^[a-f0-9]{64}$/ && $rss =~ /^[0-9]{1,10}$/ && $rss <= 2147483647;
        $measurements{$path} = [$digest, $rss];
    }
    close $file;
}
# Explicit, newly added or otherwise unmeasured roots need no graph walk:
# they cannot borrow a measured reservation and will run alone regardless.
if ($mode eq 'weights' && !(grep { exists $measurements{$_} } @roots)) {
    print "0\t$_\n" for @roots;
    exit 0;
}
my @changed = $mode eq 'changed'
    ? split(/\0/, git_output('diff', '--no-renames', '--name-only', '-z', $argument, '--')) : ();
my %paths = map { $_ => 1 } (@roots, @changed,
    split(/\0/, git_output('ls-files', '-z', '--', '*.sh')));
# Keep noncanonical imported shells in the graph, not in the root inventory.
my (%text, %edges);
for my $path (sort keys %paths) {
    next unless $path =~ /\.sh\z/;
    my $body = '';
    if (open my $file, '<', $path) { local $/; $body = <$file> // ''; close $file; }
    elsif (-e $path) { die "cannot read source graph member $path: $!\n"; }
    $text{$path} = $body;
}
my %names;
for my $path (keys %text) {
    (my $name = $path) =~ s{.*/}{};
    push @{$names{$name}}, $path;
}
my $alternatives = join '|', map { quotemeta($_) } sort keys %names;
my $name_pattern = qr/(?<![\w.-])($alternatives)(?![\w.-])/;
# Edge building matches basenames inside source references, so a literal
# operand and a literal skeleton such as "$dir/name.sh" create an edge the
# pinned ShellCheck (0.11.0) really does follow, and a literal annotation
# resolves exactly as written. A fully variable operand matches no name and
# adds no edge: the pinned ShellCheck never follows it (SC1090), so it cannot
# hide a dependency of a changed file. No shell code is evaluated anywhere in
# this analysis.
for my $path (keys %text) {
    my $body = $text{$path};
    my $source_line = qr/(?:^\s*|[;&|{}()]\s*|\b(?:then|do|if|elif|while|until|command|builtin)\s+|!\s+)(?:source|\.)\s+/;
    my $references = join "\n", grep {
        /^\s*#\s*shellcheck\s+.*\bsource=/ || /(?:^|[;\s])(?:source|\.)\s+/
    } split /\n/, $body;
    while ($references =~ /$name_pattern/g) {
        $edges{$path}{$_} = 1 for @{$names{$1}};
    }
}
sub closure {
    my ($root) = @_;
    my %seen;
    my @todo = ($root);
    while (@todo) {
        my $p = pop @todo;
        next if $seen{$p}++;
        push @todo, keys %{$edges{$p} // {}};
    }
    return sort keys %seen;
}
if ($mode eq 'changed') {
    my %changed = map { $_ => 1 } @changed;
    my $owner_change = grep { m{^bin/fm-lint(?:[./-]|$)} } @changed;
    for my $root (@roots) {
        my @deps = closure($root);
        # Selection is a demonstrated dependency only: the root itself
        # changed, a graph member it transitively sources changed, or the lint
        # owner changed and the full canonical set applies. An unrelated root
        # is never admitted on uncertainty elsewhere, matching the required
        # changed-files-plus-sourcing-roots scope.
        print "$root\n" if $owner_change || $changed{$root}
            || grep { $changed{$_} } @deps;
    }
} elsif ($mode eq 'weights' || $mode eq 'fingerprints') {
    for my $root (@roots) {
        my @deps = closure($root);
        my $digest = sha256_hex(join '', map { $_ . "\0" . ($text{$_} // '') . "\0" } @deps);
        if ($mode eq 'fingerprints') { print "$root\t$digest\n"; next; }
        my $entry = $measurements{$root};
        # A stored digest that matches the root's current closure fingerprint is
        # determined evidence about that closure's measured cost, whatever the
        # closure's sources look like: the measurement was taken over the same
        # content, so it stays valid admission data and full-lint parallelism
        # stays durable.
        my $rss = $entry && $entry->[0] eq $digest ? $entry->[1] : 0;
        print "$rss\t$root\n";
    }
} else { die "private lint plan: invalid mode\n"; }
