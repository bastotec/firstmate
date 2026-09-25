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
# Edge building matches basenames inside source references. A literal skeleton
# such as "$dir/name.sh" creates an edge the pinned ShellCheck (0.11.0) does
# NOT follow: under --norc --external-sources it drops the variable component
# and resolves the remainder relative to the process working directory, which
# fm-lint.sh sets to the repository root, then reports SC1091 because
# <root>/<basename> does not exist. Such an edge is therefore wider than what
# the pinned tool analyzes, never narrower. A `# shellcheck source=` directive
# above a source call is authoritative where present and resolves against the
# same working directory: source=/dev/null means the lint definition analyzes
# nothing there, so no edge is built from that call, while source=path is an
# edge to exactly that path. A fully variable operand with no source= in the
# contiguous comment block directly above the source call matches no name and
# adds no edge: the pinned ShellCheck reports SC1090 there and follows nothing.
# The scan enforces only that adjacency: a source= directive placed above an
# enclosing compound command is followed by the pinned ShellCheck into the
# compound body, but the scan stops at the command line and does not see it, so
# that shape can leave a changed sourced module unselected. No shell code is
# evaluated anywhere in this analysis.
my %directed;
for my $path (keys %text) {
    my $body = $text{$path};
    my @lines = split /\n/, $body;
    for (my $i = 0; $i < @lines; $i++) {
        next unless $lines[$i] =~ /(?:^|[;\s])(?:source|\.)\s+/;
        # The pinned ShellCheck reads the whole run of comment and blank lines
        # above a source call, stopping at the first line of code, and the
        # first source= directive in that run owns the call, whether it is
        # alone on its line or listed beside other directives: /dev/null
        # analyzes nothing, a path resolves as written.
        my @block;
        for (my $j = $i - 1; $j >= 0 && $lines[$j] =~ /^\s*(?:#.*)?$/; $j--) {
            unshift @block, $lines[$j];
        }
        my $directive;
        for my $comment (@block) {
            next unless $comment =~ /^\s*#\s*shellcheck\b/;
            if ($comment =~ /(?:^|\s)source=(\S+)/) { $directive = $1; last; }
        }
        if (defined $directive) {
            $directed{$path}{$directive} = 1 unless $directive eq '/dev/null';
            next;
        }
        while ($lines[$i] =~ /$name_pattern/g) {
            $edges{$path}{$_} = 1 for @{$names{$1}};
        }
    }
}
# Directive-resolved targets form an edge only when they are graph members.
for my $path (keys %directed) {
    for my $target (keys %{$directed{$path}}) {
        $edges{$path}{$target} = 1 if exists $text{$target};
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
