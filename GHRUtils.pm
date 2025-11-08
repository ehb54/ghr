package GHRUtils;
use strict;
use warnings;
use Exporter 'import';
use JSON 'decode_json', 'encode_json';
use File::Temp 'tempfile';

our @EXPORT_OK = qw(
    get_file_diff_content
    map_pos_to_line
    build_comments_json
    mark_local_comments_as_pushed
    prepare_unified_body_file
    get_session_file_path
    get_history_file_path
    load_history
    save_history
    get_current_branch
    get_unpushed_comment_count
);

# These utilities access the main program's globals via the main:: namespace

sub get_file_diff_content {
    my ($file_name_override) = @_;
    my $current_pr = $main::current_pr;
    my $current_file_name = $file_name_override || $main::current_file_name;

    if (!defined $current_pr || !defined $current_file_name) {
        return undef, "Error: No PR or file selected.\n";
    }

    my $cmd = "gh pr diff $current_pr 2>&1";
    my $full_diff = `$cmd`;

    if ($? != 0) {
        return undef, "Error running 'gh pr diff': $full_diff\n";
    }

    my $escaped_file_name = quotemeta($current_file_name);
    if ($full_diff =~ /(diff --git a\/$escaped_file_name.*?)(\ndiff --git a\/|\z)/s) {
        my $file_diff = $1;
        return $file_diff, "";
    }

    return undef, "Error: Could not find diff section for file **$current_file_name** in PR #$current_pr.\n";
}

# Map a position within the diff to a line number in the new file
sub map_pos_to_line {
    my ($target_pos, $file_name) = @_;
    my ($diff, $err) = get_file_diff_content($file_name);
    return undef, 0 if $err;

    my ($new_line, $position) = (0, 0);

    foreach my $line (split /\n/, $diff) {
        if ($line =~ /^@@ .* \+(\d+)(?:,\d+)? @@/) {
            $new_line  = $1;
            $position  = 0;
            next;
        }

        if ($line =~ /^\s/ || $line =~ /^-/) {
            $position++;
            $new_line++ if $line =~ /^\s/;
            next;
        }

        if ($line =~ /^\+/) {
            if ($position == $target_pos) {
                return $new_line, 1;
            }
            $new_line++;
            $position++;
            next;
        }
    }

    return undef, 0;
}

sub build_comments_json {
    my @gh_comments = ();
    foreach my $file_name (keys %{$main::comments{files}}) {
        my @file_comments = @{$main::comments{files}{$file_name}};
        foreach my $c (@file_comments) {
            next unless $c->{status} eq 'local';
            push @gh_comments, {
                path     => $c->{file},
                position => $c->{pos},
                body     => $c->{text},
                line     => $c->{line}
            };
        }
    }

    return undef unless @gh_comments;

    my ($fh, $filename) = tempfile(
        "ghr_comments_XXXXXX",
        DIR => "/tmp",
        UNLINK => 1
    );

    my $json_data = encode_json(\@gh_comments);
    print $fh $json_data;
    close $fh;
    print "Created temporary comments JSON file: $filename\n";
    return $filename;
}

sub mark_local_comments_as_pushed {
    for my $c (@{$main::comments{global}}) {
        $c->{status} = 'pushed' if $c->{status} eq 'local';
    }
    foreach my $file_name (keys %{$main::comments{files}}) {
        for my $c (@{$main::comments{files}{$file_name}}) {
            $c->{status} = 'pushed' if $c->{status} eq 'local';
        }
    }
}

sub prepare_unified_body_file {
    my ($review_type) = @_;
    my @global_local_comments = grep { $_->{status} eq 'local' } @{$main::comments{global}};
    my $has_local_positional = get_unpushed_comment_count() > scalar(@global_local_comments);

    unless (scalar(@global_local_comments) > 0 || $has_local_positional || $review_type ne 'comment') {
        return undef;
    }

    my $review_body = "";
    if (@global_local_comments) {
        $review_body = join("\n---\n", map { "GLOBAL COMMENT:\n" . $_->{text} } @global_local_comments);
    } elsif ($review_type ne 'comment') {
        $review_body = "Review submitted via interactive CLI.";
    }

    my $comments_section = "";
    if ($has_local_positional) {
        $comments_section .= "\n\n## Comments\n";
        foreach my $file_name (keys %{$main::comments{files}}) {
            my @file_comments = @{$main::comments{files}{$file_name}};
            foreach my $c (grep { $_->{status} eq 'local' } @file_comments) {
                $comments_section .= sprintf("- path: %s\n", $c->{file});
                $comments_section .= sprintf("  line: %s\n", $c->{line});
                $comments_section .= sprintf("  body: %s\n", $c->{text});
            }
        }
    }

    my ($fh, $temp_file) = tempfile("ghr_unified_XXXXXX", DIR => "/tmp", UNLINK => 1);
    print $fh $review_body;
    print $fh $comments_section;
    close $fh;
    return $temp_file;
}

sub get_session_file_path {
    my $home = $ENV{HOME} || $ENV{USERPROFILE} || die "Could not determine home directory (neither HOME nor USERPROFILE set)";
    return "$home/.ghr_session.json";
}

sub get_history_file_path {
    return abs_path('.') . "/.ghr_command_history";
}

sub load_history {
    my $history_file = get_history_file_path();
    if (-f $history_file) {
        open my $fh, '<', $history_file or do { warn "Warning: Could not open history file for reading: $!\n"; return; };
        my @loaded_history;
        while (my $line = <$fh>) { chomp $line; push @loaded_history, $line; }
        close $fh;
        @{$main::command_history} = @loaded_history;
        while (scalar(@{$main::command_history}) > $main::history_max_size) { shift @{$main::command_history}; }
        print "Loaded " . scalar(@{$main::command_history}) . " commands from history.\n";
    }
}

sub save_history {
    my $history_file = get_history_file_path();
    my @history_to_save = @{$main::command_history};
    while (scalar(@history_to_save) > $main::history_max_size) { shift @history_to_save; }
    open my $fh, '>', $history_file or do { warn "Warning: Could not open history file for writing: $!\n"; return; };
    foreach my $command (@history_to_save) { print $fh "$command\n"; }
    close $fh;
    print "Saved " . scalar(@history_to_save) . " commands to history file.\n";
}

sub get_current_branch {
    if (-d ".git") {
        my $branch = `git rev-parse --abbrev-ref HEAD 2>/dev/null`;
        chomp $branch;
        return $branch;
    }
    return "NOT-IN-GIT";
}

sub get_unpushed_comment_count {
    my $count = 0;
    $count += scalar(grep { $_->{status} eq 'local' } @{$main::comments{global}}) if $main::comments{global};
    foreach my $f (keys %{$main::comments{files}}) {
        $count += scalar(grep { $_->{status} eq 'local' } @{$main::comments{files}{$f}});
    }
    return $count;
}

1;
