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
my (%text, %edges, %uncertain);
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
for my $path (keys %text) {
    my $body = $text{$path};
    my $source_line = qr/(?:^\s*|[;&|{}()]\s*|\b(?:then|do|if|elif|while|until|command|builtin)\s+|!\s+)(?:source|\.)\s+/;
    my $references = join "\n", grep {
        /^\s*#\s*shellcheck\s+.*\bsource=/ || /(?:^|[;\s])(?:source|\.)\s+/
    } split /\n/, $body;
    while ($references =~ /$name_pattern/g) {
        $edges{$path}{$_} = 1 for @{$names{$1}};
    }
    # A variable-only source without an explicit ShellCheck boundary cannot be
    # resolved statically. Admit it conservatively for every shell change, and
    # never allow it to use a measured light-root reservation.
    my $annotation = 0;
    for my $line (split /\n/, $body) {
        if ($line =~ /^\s*#\s*shellcheck\s+.*\bsource=([^\s]+)/) {
            my $target = $1;
            $annotation = 1;
            # Unsupported/wildcard annotations must widen, never silently drop
            # dependencies that ShellCheck may follow.
            $uncertain{$path} = 1 if $target ne '/dev/null' && !exists $text{$target};
            next;
        }
        next if $line =~ /^\s*(?:#.*)?$/;
        if ($line =~ /$source_line([^;\n]+)/) {
            my $operand = $1;
            my $known = $operand =~ /$name_pattern/;
            # A missing literal import has no readable dependency. Dynamic
            # operands may name any shell; do not mistake jq's `. as $value`
            # expressions inside quoted programs for dynamic shell imports.
            my $dynamic = $operand =~ /^(?:["']|[^\s]*[\$`])/;
            $uncertain{$path} = 1 if !$annotation && !$known && $dynamic;
        }
        $annotation = 0;
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
    my $shell_change = grep { /\.sh\z/ } @changed;
    my $owner_change = grep { m{^bin/fm-lint(?:[./-]|$)} } @changed;
    for my $root (@roots) {
        my @deps = closure($root);
        print "$root\n" if $owner_change || $changed{$root}
            || grep { $changed{$_} || ($shell_change && $uncertain{$_}) } @deps;
    }
} elsif ($mode eq 'weights' || $mode eq 'fingerprints') {
    for my $root (@roots) {
        my @deps = closure($root);
        my $digest = sha256_hex(join '', map { $_ . "\0" . ($text{$_} // '') . "\0" } @deps);
        if ($mode eq 'fingerprints') { print "$root\t$digest\n"; next; }
        my $entry = $measurements{$root};
        my $rss = $entry && $entry->[0] eq $digest && !(grep { $uncertain{$_} } @deps)
            ? $entry->[1] : 0;
        print "$rss\t$root\n";
    }
} else { die "private lint plan: invalid mode\n"; }
