#!/usr/bin/env bash
# Data contract for fm-remote-home-seed.sh --migrate and the provision receiver.
# No standalone command. Migration v1 transfers bounded regular-file records,
# never tar entries, project trees, Git objects, credentials, or executable
# runtime state. data/ and known non-secret config are live; state/ is retained
# byte-exact as inert evidence under .fm-migration/state/. The captain inbox and
# pending-reply records additionally retain their operational locations.
# Original charter and parent binding remain in .fm-migration/; only the active
# charter's home, parent status, and steering-inbox paths change placement.
# A source freeze marker is permanent until explicit later operator recovery:
# it is not permission to discard the home or return its treehouse lease.
# Perl's core JSON::PP, MIME::Base64, Digest::SHA, and File::Find avoid a new
# dependency and reject traversal, links, special files, duplicate destinations,
# unknown config, oversized payloads, and digest mismatches before publication.
# fm_migration_receive runs only inside fm-remote-home-provision.sh and takes its
# serialization key and file digests from that script's own helpers, so a seed
# and a migration racing for one remote home cannot pick different lock paths.

# Single owner of the migration payload bound, in bytes. It caps each packed
# file, the encoded bundle, and the bytes the receiver will read, and it is the
# one carve-out fm-remote-job-lib.sh grants over its ordinary stdin ceiling.
FM_MIGRATION_MAX_BYTES=67108864

fm_migration_data() { # pack <source> <parent-state> <id> <remote-home> | unpack/check <home> <id> <bundle>
  FM_MIGRATION_MAX_BYTES="$FM_MIGRATION_MAX_BYTES" perl - "$@" <<'PERL'
use strict;
use warnings;
use JSON::PP;
use MIME::Base64 qw(encode_base64 decode_base64);
use Digest::SHA qw(sha256_hex);
use File::Find;
use File::Path qw(make_path);
use Fcntl qw(:mode);
my ($op, $home, $arg, $id, $remote) = @ARGV;
my $limit = $ENV{FM_MIGRATION_MAX_BYTES};
sub readfile {
    my ($p) = @_;
    my @s = lstat($p);
    die "unsafe regular file: $p\n" unless @s && S_ISREG($s[2]) && $s[3] == 1;
    die "oversized file: $p\n" if $s[7] > $limit;
    open my $f, '<', $p or die "$p: $!\n";
    binmode $f; local $/; return <$f>;
}
sub safe {
    my ($p) = @_;
    return $p =~ m{\A[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*\z}
        && !grep { $_ eq '.' || $_ eq '..' } split '/', $p;
}
sub secret {
    my ($p) = @_;
    return $p =~ m{(?:\A|/)(?:\.env(?:\..*)?|\.ssh|\.aws|\.gnupg|\.azure|\.pi|\.claude|\.codex|\.config|credentials?(?:\..*)?|secrets?(?:\..*)?|auth\.json|cmux-socket-password)(?:/|\z)}i
        || $p =~ /\.(?:pem|key|p12|pfx|keychain(?:-db)?)\z/i;
}
my %config = map { $_ => 1 } qw(crew-harness crew-dispatch.json secondmate-harness
    backlog-backend backend herdr-presentation-spaces startup-memory-budget trace-context
    launch-env-allowlist claude-permission-mode calm supervision-branch-model
    supervision-branch-effort stow-pass-horizon turnend-churn-absorb wedge-alarm watched-tools.json);
sub allowed {
    my ($p, $who) = @_;
    return 0 unless safe($p) && !secret($p);
    return 1 if $p =~ m{\Adata/} && $p !~ m{\Adata/\.parent-route(?:/|\z)};
    return 1 if $p =~ m{\Aconfig/([^/]+)\z} && $config{$1};
    return 1 if $p =~ m{\A\.fm-migration/(?:state/|original-charter\.md\z|original-parent\z)};
    return 1 if $p =~ m{\Astate/(?:inbox/|pending-replies/)};
    return 1 if $p =~ m{\Astate/parent-route/\Q$who\E\.inbox/(?:[0-9]+\.msg|handled/[0-9]+\.msg)\z};
    return 0;
}
if ($op eq 'pack') {
    die "unsafe identity\n" unless $id =~ /\A[A-Za-z0-9_-][A-Za-z0-9._-]*\z/;
    my (@records, @excluded);
    my %seen;
    my $add = sub {
        my ($src, $dest, $bytes) = @_;
        die "unsafe destination: $dest\n" unless allowed($dest, $id);
        die "duplicate destination: $dest\n" if $seen{$dest}++;
        $bytes = readfile($src) unless defined $bytes;
        push @records, {path => $dest, bytes => encode_base64($bytes, ''), sha256 => sha256_hex($bytes)};
    };
    for my $dir (qw(data config state)) {
        next unless -e "$home/$dir" || -l "$home/$dir";
        die "unsafe directory: $dir\n" unless -d "$home/$dir" && !-l "$home/$dir";
        find({no_chdir => 1, wanted => sub {
            my $src = $File::Find::name;
            my $rel = substr($src, length($home) + 1);
            my @s = lstat($src); die "cannot inspect $src\n" unless @s;
            if (secret($rel)) { push @excluded, $rel; $File::Find::prune = 1 if S_ISDIR($s[2]); return; }
            die "unsafe path: $rel\n" unless safe($rel);
            # Runtime locks and old parent endpoint wiring are not durable work.
            if ($rel =~ m{\A(?:state/(?:.*\.lock(?:\.[^/]*)?|parent-route)(?:/|\z)|data/\.parent-route(?:/|\z))}) {
                $File::Find::prune = 1 if S_ISDIR($s[2]); return;
            }
            return if S_ISDIR($s[2]);
            die "unsafe artifact: $rel\n" unless S_ISREG($s[2]) && $s[3] == 1;
            if ($dir eq 'config') { die "unclassified config: $rel\n" unless $config{substr($rel, 7)}; }
            my $dest = $dir eq 'state' ? '.fm-migration/' . $rel : $rel;
            my $bytes = readfile($src);
            if ($rel eq 'data/charter.md') {
                $add->($src, '.fm-migration/original-charter.md', $bytes);
                $bytes =~ s{\Q$arg/$id.status\E}{$remote/state/parent-replies.status}g;
                $bytes =~ s{\Q$arg/$id.inbox\E}{$remote/state/parent-route/$id.inbox}g;
                $bytes =~ s{\Q$home\E}{$remote}g;
            }
            $add->($src, $dest, $bytes);
            $add->($src, $rel, $bytes) if $rel =~ m{\Astate/(?:inbox/|pending-replies/)};
        }}, "$home/$dir");
    }
    $add->("$home/.fm-secondmate-parent", '.fm-migration/original-parent');
    my $inbox = "$arg/$id.inbox";
    if (-e $inbox || -l $inbox) {
        die "unsafe steering inbox\n" unless -d $inbox && !-l $inbox;
        find({no_chdir => 1, wanted => sub {
            my $p = $File::Find::name;
            return if $p eq $inbox;
            my $r = substr($p, length($inbox) + 1);
            if ($r eq '.seq.lock') { $File::Find::prune = 1; return; }
            return if $r eq 'handled' && -d $p && !-l $p;
            die "unclassified inbox artifact: $r\n" unless $r =~ m{\A(?:handled/)?[0-9]+\.msg\z};
            $add->($p, "state/parent-route/$id.inbox/$r");
        }}, $inbox);
    }
    my $json = JSON::PP->new->canonical->encode({schema => 'fm-home-migration.v1', id => $id,
        records => [sort {$a->{path} cmp $b->{path}} @records], excluded => [sort @excluded]});
    die "migration exceeds its payload bound\n" if length($json) > $limit;
    print $json;
} elsif ($op eq 'unpack' || $op eq 'check') {
    # argv: operation, destination home, identity, bundle filename
    my $who = $arg;
    my $j = decode_json(readfile($id));
    die "wrong migration identity/schema\n" unless $j->{schema} eq 'fm-home-migration.v1' && $j->{id} eq $who;
    my %seen;
    my @decoded;
    for my $r (@{$j->{records}}) {
        my $p = $r->{path};
        die "unsafe/duplicate migration path\n" unless allowed($p, $who) && !$seen{$p}++;
        my $bytes = decode_base64($r->{bytes});
        die "invalid record encoding/digest: $p\n" unless encode_base64($bytes, '') eq $r->{bytes} && sha256_hex($bytes) eq $r->{sha256};
        push @decoded, [$p, $bytes];
    }
    die "missing durable charter/backlog\n" unless $seen{'data/charter.md'} && $seen{'data/backlog.md'};
    for my $r (@decoded) {
        my ($p, $bytes) = @$r;
        my @parts = split '/', $p; pop @parts;
        my $dir = $home;
        die "unsafe destination home\n" unless -d $dir && !-l $dir;
        for my $part (@parts) {
            $dir .= "/$part";
            die "unsafe destination directory\n" if -l $dir || (-e $dir && !-d $dir);
            mkdir($dir, 0700) or die "$dir: $!\n" unless -d $dir || $op eq 'check';
        }
        my $dest = "$home/$p";
        if ($op eq 'check') { die "verification mismatch: $p\n" unless readfile($dest) eq $bytes; next; }
        readfile($dest) if -e $dest || -l $dest;
        open my $f, '>', $dest or die "$dest: $!\n";
        binmode $f; print {$f} $bytes or die "$dest: $!\n";
        close $f or die "$dest: $!\n";
        chmod($p eq 'data/captain-shared.md' ? 0444 : 0600, $dest) or die "$dest: $!\n";
    }
} else { die "unknown migration data operation\n"; }
PERL
}

fm_migration_receive() { # --migration|--migration-verify <id> <sha256>
  local action=$1 id=$2 digest=$3 parent lock_root lock_dir temp stage actual
  case "$id" in ''|-*|*[!A-Za-z0-9._-]*) die 'invalid migration identity' ;; esac
  case "$digest" in *[!a-f0-9]*|'') die 'invalid migration digest' ;; esac
  [ "${#digest}" -eq 64 ] || die 'invalid migration digest length'
  parent=$(dirname "$FM_HOME")
  [ "$(cd "$parent" && pwd -P)" = "$parent" ] || die 'migration parent must be canonical'
  # Both lock paths come from the provisioning owner, so a seed and a migration
  # racing for this same home contend on one lock rather than two spellings.
  provision_resolve_home_lock "$FM_HOME" || die 'cannot resolve the provisioning lock'
  lock_root=$PROVISION_LOCK_STATE
  lock_dir=$PROVISION_LOCK
  [ ! -L "$lock_root" ] || die 'unsafe provisioning lock directory'
  mkdir -p "$lock_root"
  FM_STATE_OVERRIDE="$lock_root"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_try_acquire "$lock_dir" || die 'remote provisioning already in progress'
  # Failed staging is retained and a populated home is never removed in any
  # migration failure path; only a completed publication clears its own staging.
  # The trap releases only this owned lock.
  trap 'fm_lock_release "$lock_dir" || true' EXIT
  if [ -e "$FM_HOME" ] || [ -L "$FM_HOME" ]; then
    [ -d "$FM_HOME" ] && [ ! -L "$FM_HOME" ] \
      && [ -d "$FM_HOME/.fm-migration" ] && [ ! -L "$FM_HOME/.fm-migration" ] \
      && [ -f "$FM_HOME/.fm-migration/digest" ] && [ ! -L "$FM_HOME/.fm-migration/digest" ] \
      && [ "$(cat "$FM_HOME/.fm-migration/digest")" = "$digest" ] \
      && [ -f "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ] \
      && [ "$(cat "$FM_HOME/.fm-secondmate-home")" = "$id" ] || die 'destination is not this staged migration; no overwrite allowed'
    fm_migration_data check "$FM_HOME" "$id" "$FM_HOME/.fm-migration/bundle.json" || die 'staged durable data no longer matches; reconcile on this host'
    printf 'verified-migration: %s %s\n' "$id" "$digest"
    fm_lock_release "$lock_dir"
    trap - EXIT
    return 0
  fi
  [ "$action" = --migration ] || die 'migration home not yet staged'
  umask 077
  temp=$(mktemp -d "$parent/.fm-migration-$id.XXXXXX") || die 'cannot stage migration'
  head -c "$((FM_MIGRATION_MAX_BYTES + 1))" > "$temp/bundle.json"
  [ "$(wc -c < "$temp/bundle.json" | tr -d ' ')" -le "$FM_MIGRATION_MAX_BYTES" ] \
    || die 'migration exceeds its payload bound'
  actual=$(provision_file_sha256 "$temp/bundle.json") || die 'cannot digest the migration payload'
  [ "$actual" = "$digest" ] || die 'migration transport digest mismatch'
  stage="$temp/home"
  # Decode and validate ALL records before cloning any project. This staging
  # tree is private and absent, not the existing destination home.
  mkdir "$temp/records"
  fm_migration_data unpack "$temp/records" "$id" "$temp/bundle.json" || die 'invalid migration records'
  jq -er '.provision' "$temp/bundle.json" > "$temp/provision" || die 'missing provisioning manifest'
  FM_HOME="$stage" "$SCRIPT_DIR/fm-remote-home-provision.sh" < "$temp/provision" || die 'remote migration provisioning failed; staging retained'
  [ "$(cat "$stage/.fm-secondmate-home")" = "$id" ] || die 'provisioning identity differs from migration'
  fm_migration_data unpack "$stage" "$id" "$temp/bundle.json" || die 'cannot install migration records'
  fm_migration_data check "$stage" "$id" "$temp/bundle.json" || die 'migration verification failed'
  cp "$temp/bundle.json" "$stage/.fm-migration/bundle.json"
  printf '%s\n' "$digest" > "$stage/.fm-migration/digest"
  [ ! -e "$FM_HOME" ] && [ ! -L "$FM_HOME" ] || die 'destination appeared during staging'
  mv "$stage" "$FM_HOME"
  # The published home already carries the bundle it was verified against, so the
  # private staging copies of the same durable records are removed rather than
  # left duplicating the home outside it. Only a completed publication clears
  # them; every failure path above still retains its staging for reconciliation.
  rm -rf -- "$temp"
  printf 'verified-migration: %s %s\n' "$id" "$digest"
  fm_lock_release "$lock_dir"
  trap - EXIT
}
