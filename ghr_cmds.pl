use strict;
use warnings;
use FindBin '$Bin';
use lib $Bin;

# Command Dispatch Table (sub refs refer to subs defined below)
our %COMMANDS = (
    'q'       => \&cmd_quit,
    '?'       => \&cmd_help,
    'h'       => \&cmd_history,
    'lpr'     => \&cmd_list_prs,
    'lc'      => \&cmd_load_comments,
    'lgc'     => \&cmd_load_general_comments,
    'pr'      => \&cmd_select_pr,
    'lf'      => \&cmd_list_files,
    'fn'      => \&cmd_select_file,
    'f'       => \&cmd_select_file_name_regexp,
    '+'       => \&cmd_select_file,
    '-'       => \&cmd_select_file,
    'dd'      => \&cmd_show_diffs,
    'g'       => \&cmd_grep_diffs,
    'gl'      => \&cmd_grep_local,
    'g+'      => \&cmd_grep_diffs_next,
    'g-'      => \&cmd_grep_diffs_prev,
    'ddiw'    => \&cmd_show_diffs_ignore_whitespace,
    'do'      => \&cmd_show_original,
    'dn'      => \&cmd_show_new,
    'ca'      => \&cmd_add_comment,
    'cd'      => \&cmd_delete_comment,
    'cp'      => \&cmd_push_comments,
    'rs'      => \&cmd_review_summary,
    'accept'  => \&cmd_accept_review,
    'reject'  => \&cmd_reject_review,
    'ajim'    => \&cmd_gemini_chat,
    'agtp'    => \&cmd_openai_chat,
);

sub cmd_quit {
    my $unpushed_count = get_unpushed_comment_count();
    if ($unpushed_count > 0) {
        print "Warning: You have $unpushed_count unpushed local comments.\n";
        print "Are you sure you want to quit without pushing? (y/N): ";
        my $confirm = <STDIN>;
        return unless $confirm =~ /^[yY]/;
    }

    if (defined $current_pr && defined $current_file_name) {
        my $session_file_path = get_session_file_path();
        my $session_data = {
            pr_num => $current_pr,
            file_name => $current_file_name
        };

        eval {
            open(my $fh, '>', $session_file_path) or die "Could not open file '$session_file_path': $!";
            print $fh JSON->new->pretty(1)->encode($session_data);
            close $fh;
            print "Session state saved to $session_file_path\n";
        };
        if ($@) {
            print "Warning: Failed to save session state: $@\n";
        }
    }

    exit 0;
}

sub cmd_help {
    print <<'HELP_TEXT';
## GitHub Review CLI (ghr) Help

q         // quit (or control-D/EOF)
h         // command history
?         // print this help
lpr       // list PRs (Uses 'gh pr list')
pr PR#    // select PR (e.g., 'pr 123')
lf        // list files in the current PR
lc        // list pushed comments in the current PR
lgc       // list global comments in the current PR
fn file#  // select file by number, or use '+' or '-' for next/previous
f name    // file by name regex
+         // select next file and show diffs
-         // select previous file and show diffs
dd        // show diffs for selected file
ddiw      // show diffs for selected file ignore whitespace
do        // show original lines for selected file (with line numbers)
dn        // show new lines for selected file (with positional info)
g regexp  // grep diffs and list files and their file numbers that match
gl regexp // grep local files
g+        // select next file from last g set
g-        // select previous file from last g set
ca pos    // add comment. 'pos' is position # from 'sn', or 'g' for global.
cd pos    // delete comment by position # or 'g' for global.
cp        // pushes all local comments to GitHub (asks confirmation)
rs        // review summary (all local and pushed comments)
accept    // accept PR (asks confirmation, pushes comments)
reject    // reject PR (asks confirmation, pushes comments)

HELP_TEXT
}

sub cmd_list_prs {
    print "Fetching list of open pull requests...\n";
    system('gh pr list --state open --limit 50');
}

sub cmd_select_pr {
    my ($pr_num, $filenumber) = @_;
    $filenumber = 1 unless defined $filenumber;

    if ($pr_num =~ /^\d+$/) {
        my @files = `gh api --paginate "repos/{owner}/{repo}/pulls/$pr_num/files" --jq ".[].filename" 2>/dev/null`;
        if ($? != 0) {
            print "Error: PR #$pr_num not found or inaccessible.\n";
            return;
        }

        @pr_files = ();
        %files_data = ();

        my $count = 0;
        foreach my $f (@files) {
            chomp $f;
            $f =~ s/^"|"$//g;
            next unless length $f;
            push @pr_files, $f;
            $files_data{$f} = 1;
            $count++;
        }

        $current_pr = $pr_num;
        $current_file_index = undef;
        $current_file_name = undef;
        %comments = (
            'global' => [],
            'files' => {},
            'review_state' => undef
        );

        print "Selected PR #$current_pr with $count files.\n";

        if ($filenumber > 0 && $filenumber <= $count) {
            cmd_select_file($filenumber, 1);
        }
    } else {
        print "Usage: pr <PR#>\n";
    }
}

sub cmd_list_files {
    if (!defined $current_pr) {
        print "No PR selected. Use 'pr <PR#>' first.\n";
        return;
    }

    my @list = @pr_files ? @pr_files : sort keys %files_data;
    print "Files in PR #$current_pr:\n";
    for my $i (0 .. $#list) {
        my $status = defined $comments{files}{$list[$i]} ? "(C)" : "";
        print sprintf(" %2d: %s %s\n", $i + 1, $list[$i], $status);
    }
}

sub cmd_select_file {
    my ($arg, $quiet) = @_;

    if (!defined $current_pr) {
        print "Error: No PR selected. Use 'pr <PR#>' first.\n";
        return;
    }

    my @list = @pr_files ? @pr_files : sort keys %files_data;
    my $max_index = scalar @list;

    if ($max_index == 0) {
        print "No files available for PR #$current_pr.\n";
        return;
    }

    my $new_index;
    my $is_nav_command = 0;

    if ($arg eq '+') {
        $new_index = defined $current_file_index ? $current_file_index + 1 : 1;
        if ($new_index > $max_index) { print "End of file list reached (at file $max_index).\n"; return; }
        $is_nav_command = 1;
    } elsif ($arg eq '-') {
        unless (defined $current_file_index) { print "No file currently selected. Cannot move backward.\n"; return; }
        $new_index = $current_file_index - 1;
        if ($new_index < 1) { print "Beginning of file list reached (at file 1).\n"; return; }
        $is_nav_command = 1;
    } elsif (defined $arg && $arg =~ /^\d+$/) {
        $new_index = int($arg);
        if ($new_index < 1 || $new_index > $max_index) { print "Error: File number $arg is out of range (1-$max_index).\n"; return; }
        $is_nav_command = 1;
    } elsif (!defined $arg || $arg eq '') {
        print "Usage: fn <file#> | + | -\n";
        return;
    } else {
        print "Unrecognized argument for file selection: '$arg'.\n";
        return;
    }

    $current_file_index = $new_index;
    $current_file_name  = $list[$current_file_index - 1];

    print "Selected file $current_file_name ($current_file_index/$max_index).\n";

    if (exists $comments{files}{$current_file_name} && @{$comments{files}{$current_file_name}}) {
        print "\nLocal/Pushed comments for this file:\n";
        foreach my $c (@{$comments{files}{$current_file_name}}) {
            my $status = ($c->{status} eq 'local') ? '[LOCAL]' : '[PUSHED]';
            print "  $status Pos: $c->{pos}, Line: $c->{line} -> \"$c->{text}\"\n";
        }
        print "\n";
    }

    if ($is_nav_command && !$quiet) {
        cmd_show_diffs();
    }
}

sub cmd_show_diffs {
    my ($diff, $err) = get_file_diff_content(); 
    if ($err) { print $err; return; }
    print "$diff\n";
}

sub cmd_show_original {
    my ($diff, $err) = get_file_diff_content();
    if ($err) {
        print $err;
        return;
    }

    my ($original_line, $new_line) = (0, 0);
    my $is_new_file = 0;

    print "\n--- Original Changed Lines in $current_file_name ---\n";

    foreach my $line (split /\n/, $diff) {
        if ($line =~ /^new file mode/) {
            $is_new_file = 1;
        }

        if ($line =~ /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/) {
            $original_line = $1;
            $new_line = $2;
            
            if ($original_line == 0) {
                print "\n-- Hunk starts (New File: No original lines to show) --\n";
                next; 
            }
            
            print "\n-- Hunk starts (Original Line $original_line) --\n";
            next;
        }

        next if $line !~ /^[ \-+\\]/;

        if ($line =~ /^\s/) {
            $original_line++;
            $new_line++;
            next;
        }
        elsif ($line =~ /^-/) {
            if (!$is_new_file) {
                print sprintf("%4d: %s\n", $original_line, substr($line, 1));
            }
            $original_line++;
            next;
        }
        elsif ($line =~ /^\+/) {
            $new_line++;
            next;
        }
    }
    
    if ($is_new_file) {
        print "\nFile **$current_file_name** is a new file. No 'Original' lines exist.\n";
    }
}

sub cmd_show_new {
    my ($diff, $err) = get_file_diff_content();
    if ($err) {
        print $err;
        return;
    }

    my ($new_line, $position) = (0, 0);
    my $is_removed_file = 0;

    print "\n--- New Changed Lines in $current_file_name (for 'ca' command) ---\n";

    foreach my $line (split /\n/, $diff) {
        if ($line =~ /^deleted file mode/) {
            $is_removed_file = 1;
        }

        if ($line =~ /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/) {
            $new_line  = $2;
            $position  = 0;
            
            if ($new_line == 0) {
                print "\n-- Hunk starts (Removed File: No new lines to comment) --\n";
                next;
            }
            
            print "\n-- Hunk starts (New Line $new_line) --\n";
            next;
        }

        next if $line !~ /^[ \-+\\]/;

        if ($line =~ /^\s/) {
            $new_line++;
            $position++;
            print sprintf("%4s:%4d: %s\n", '', $new_line, substr($line, 1));
            next;
        }
        elsif ($line =~ /^-/) {
            $position++;
            print sprintf("%4s:%4s: %s\n", '', '-', substr($line, 1));
            next;
        }
        elsif ($line =~ /^\+/) {
            print sprintf("%4d:%4d: %s\n", $position, $new_line, substr($line, 1));
            $new_line++;
            $position++;
            next;
        }
    }
    
    if ($is_removed_file) {
        print "\nFile **$current_file_name** is a removed file. Comments can only be added to lines that still exist.\n";
    } else {
        print "\nNote: Use the **first column number** (Position #) with 'ca' command.\n";
    }
}

sub cmd_add_comment {
    my ($args) = @_;
    my ($pos, $initial_text) = split /\s+/, $args, 2;
    $pos = lc $pos;
    
    if (!defined $pos || ($pos ne 'g' && $pos !~ /^\d+$/)) {
        print "Usage: ca <position # | g> [initial comment text]\n";
        print "  'g' is for a global review comment.\n";
        print "  Position # is found via the 'sn' command.\n";
        return;
    }

    my $target_type;
    my $target_key;
    my $line_num_for_push = undef;

    if ($pos eq 'g') {
        $target_type = 'global';
        $target_key = 'global';
        print "Adding a GLOBAL comment. Type your comment, terminate with a '.' on a single line:\n";
    } else {
        if (!defined $current_file_name) {
            print "Error: Cannot add positional comment. No file selected. Use 'sf' first.\n";
            return;
        }
        $target_type = 'positional';
        $target_key = $current_file_name;
        ($line_num_for_push, my $valid) = _map_pos_to_line($pos, $current_file_name);
        if (!$valid) {
            print "Error: Position #$pos is invalid for file **$current_file_name**. Use 'sn' to see valid positions.\n";
            return;
        }

        print "Adding comment at position **$pos** (Line $line_num_for_push) in **$current_file_name**.\n";
        print "Type your comment, terminate with a '.' on a single line:\n";
    }

    my $comment_text = defined $initial_text ? $initial_text : "";
    $comment_text .= "\n" if $comment_text ne ""; 

    while (<STDIN>) {
        chomp;
        last if $_ eq '.';
        $comment_text .= "$_\n";
    }

    my $new_comment = {
        text   => $comment_text,
        status => 'local',
        pos    => $pos,
        ($target_type eq 'positional' ? (
            file => $current_file_name,
            line => $line_num_for_push
        ) : ())
    };

    if ($target_type eq 'positional' && !exists $comments{files}{$target_key}) {
        $comments{files}{$target_key} = [];
    }

    my $storage = ($target_type eq 'global') ? $comments{global} : $comments{files}{$target_key};
    push @$storage, $new_comment;

    print "\nComment added successfully (local: $target_type, pos: $pos).\n";
}

sub cmd_delete_comment {
    my ($pos) = @_;
    $pos = lc $pos;

    if (!defined $pos || ($pos ne 'g' && $pos !~ /^\d+$/)) {
        print "Usage: cd <comment_index | g>\n";
        print "  'g' deletes a GLOBAL comment (requires index).\n";
        print "  Comment index is found by listing comments (e.g., using 'rs' or 'sf').\n";
        return;
    }
    
    my $target_type;
    my $comment_storage;

    if ($pos eq 'g') {
        $target_type = 'global';
        $comment_storage = $comments{global};
        print "Existing GLOBAL comments:\n";
    } else {
        if (!defined $current_file_name) {
            print "Error: Cannot delete positional comment. No file selected. Use 'sf' first.\n";
            return;
        }
        $target_type = 'positional';
        $comment_storage = $comments{files}{$current_file_name} // [];
        print "Existing comments in **$current_file_name**:\n";
    }
    
    if (!@$comment_storage) {
        print "No $target_type comments exist to delete.\n";
        return;
    }

    my @indices_to_delete;
    for my $i (0 .. $#$comment_storage) {
        my $c = $comment_storage->[$i];
        my $status = ($c->{status} eq 'local') ? '[L]' : '[P]';
        my $info = ($target_type eq 'positional') ? "Pos: $c->{pos}, Line: $c->{line}" : "";
        print sprintf(" [%2d] %s %s: %s\n", $i + 1, $status, $info, substr($c->{text}, 0, 50) . '...');
    }
    
    print "\nEnter the **index number** (1 to " . scalar(@$comment_storage) . ") to delete, or 'a' for all, or 'c' to cancel: ";
    my $delete_input = <STDIN>;
    chomp $delete_input;

    if ($delete_input =~ /^\d+$/) {
        my $idx = $delete_input - 1;
        if ($idx >= 0 && $idx <= $#$comment_storage) {
            push @indices_to_delete, $idx;
        } else {
            print "Error: Invalid index.\n";
            return;
        }
    } elsif (lc $delete_input eq 'a') {
        @indices_to_delete = (0 .. $#$comment_storage);
    } else {
        print "Deletion cancelled.\n";
        return;
    }

    @indices_to_delete = sort {$b <=> $a} @indices_to_delete;
    
    my $deleted_count = 0;
    foreach my $idx (@indices_to_delete) {
        splice(@$comment_storage, $idx, 1);
        $deleted_count++;
    }

    if ($target_type ne 'global' && !@$comment_storage) {
        delete $comments{files}{$current_file_name};
    }
    
    print "Successfully deleted $deleted_count $target_type comment(s).\n";
}

sub cmd_review_summary {
    print "\n======================================================\n";
    print "### 📋 REVIEW SUMMARY for PR #$current_pr ###\n";
    print "======================================================\n";

    my $review_state = $comments{review_state} // 'PENDING';
    print "Review Status: **$review_state**\n";
    print "------------------------------------------------------\n";

    my @global_comments = @{$comments{global}};
    if (@global_comments) {
        print "### 🌎 Global Comments: (" . scalar(@global_comments) . ") ###\n";
        
        my $local_count = 0;
        my $pushed_count = 0;
        
        for my $i (0 .. $#global_comments) {
            my $c = $global_comments[$i];
            my $status = $c->{status};
            
            if ($status eq 'local') {
                $local_count++;
            } else {
                $pushed_count++;
            }
            
            print sprintf(" [%2d] %s: %s\n", $i + 1, uc($status), $c->{text});
        }
        
        print "  -> Summary: **$local_count Local**, **$pushed_count Pushed**\n";
        print "------------------------------------------------------\n";
    } else {
        print "### 🌎 Global Comments: None ###\n";
        print "------------------------------------------------------\n";
    }

    my @commented_files = sort keys %{$comments{files}};
    
    if (@commented_files) {
        print "### 📂 File Positional Comments: (" . scalar(@commented_files) . " files) ###\n";
        
        my $total_local_count = 0;
        my $total_pushed_count = 0;

        foreach my $file_name (@commented_files) {
            my @file_comments = @{$comments{files}{$file_name}};
            next unless @file_comments;
            
            print "\nFile: **$file_name** (" . scalar(@file_comments) . " comments)\n";

            my $file_local_count = 0;
            my $file_pushed_count = 0;
            
            for my $i (0 .. $#file_comments) {
                my $c = $file_comments[$i];
                my $status = $c->{status};
                
                if ($status eq 'local') {
                    $file_local_count++;
                } else {
                    $file_pushed_count++;
                }

                print sprintf(" [%2d] %s (Pos: %-4s | Line: %-4s) %s\n", 
                    $i + 1, uc($status), $c->{pos}, $c->{line}, $c->{text});
            }
            
            $total_local_count += $file_local_count;
            $total_pushed_count += $file_pushed_count;
        }

        print "\n--- TOTAL POSITIONAL SUMMARY ---\n";
        print "  -> **$total_local_count Local** comments across " . scalar(@commented_files) . " files.\n";
        print "  -> **$total_pushed_count Pushed** comments.\n";
        print "------------------------------------------------------\n";
    } else {
        print "### 📂 File Positional Comments: None ###\n";
        print "------------------------------------------------------\n";
    }
}

sub cmd_push_comments {
    my $unpushed_count = get_unpushed_comment_count();

    if ($unpushed_count == 0) {
        print "No new local comments to push for PR #$current_pr.\n";
        return;
    }
    
    print "\nYou have **$unpushed_count** local comments (global and positional).\n";
    print "Are you sure you want to push these comments to GitHub now? (y/N): ";
    my $confirm = <STDIN>;
    chomp $confirm;

    return unless $confirm =~ /^[yY]/;
    
    my $temp_file = undef; 
    
    $temp_file = _prepare_unified_body_file('comment');
    
    unless (defined $temp_file) {
        print "Error: Failed to create unified comment body file.\n";
        return;
    }
    
    my @cmd_parts = ("gh", "pr", "review", $current_pr, "--comment", "--body-file", $temp_file);

    print "\nPushing comments via GitHub CLI...\n";
    my $final_cmd = join(" ", map { s/ /\\ /g; $_ } @cmd_parts);
    print "Executing: $final_cmd\n";
    
    my $output = system(@cmd_parts);

    if ($output == 0) {
        print "\n✅ Successfully pushed all $unpushed_count comment(s) to PR #$current_pr.\n";
        _mark_local_comments_as_pushed();
    } else {
        print "\n❌ Error pushing comments. Check gh CLI output above. Error code: $output\n";
    }
    
    if (defined $temp_file && -e $temp_file) {
        unlink $temp_file;
    }
}

sub cmd_accept_review {
    return unless defined $current_pr;
    $comments{review_state} = 'APPROVE';
    
    cmd_review_summary();
    
    print "\n======================================================\n";
    print "CONFIRM: You are submitting an **APPROVAL** of PR #$current_pr.\n";
    print "This will push all local comments and finalize the review.\n";
    print "Are you sure you want to proceed? (y/N): ";
    my $confirm = <STDIN>;
    chomp $confirm;

    if ($confirm =~ /^[yY]/) {
        _submit_review('approve');
    } else {
        $comments{review_state} = 'PENDING';
        print "Approval submission cancelled.\n";
    }
}

sub cmd_reject_review {
    return unless defined $current_pr;
    $comments{review_state} = 'REQUEST_CHANGES';
    
    cmd_review_summary();
    
    print "\n======================================================\n";
    print "CONFIRM: You are submitting a **REQUEST FOR CHANGES** on PR #$current_pr.\n";
    print "This will push all local comments and finalize the review.\n";
    print "Are you sure you want to proceed? (y/N): ";
    my $confirm = <STDIN>;
    chomp $confirm;

    if ($confirm =~ /^[yY]/) {
        _submit_review('request_changes');
    } else {
        $comments{review_state} = 'PENDING';
        print "Rejection submission cancelled.\n";
    }
}

sub _submit_review {
    my ($review_type) = @_;
    
    my $temp_file = undef; 
    
    $temp_file = _prepare_unified_body_file($review_type);

    unless (defined $temp_file) {
        my $default_body = $review_type eq 'approve' ? "Approved." : "Changes requested.";
        my ($fh, $filename) = tempfile("ghr_minimal_XXXXXX", DIR => "/tmp", UNLINK => 1);
        print $fh $default_body;
        close $fh;
        $temp_file = $filename;
    }

    my $flag = ($review_type eq 'approve') ? '--approve' : '--request-changes';
    
    my @cmd_parts = ("gh", "pr", "review", $current_pr, $flag, "--body-file", $temp_file);
    
    print "\nSubmitting review via GitHub CLI...\n";
    my $final_cmd = join(" ", map { s/ /\\ /g; $_ } @cmd_parts);
    print "Executing: $final_cmd\n";
    
    my $output = system(@cmd_parts);

    if ($output == 0) {
        print "\n✅ Successfully submitted review as " . uc($review_type) . " for PR #$current_pr.\n";
        _mark_local_comments_as_pushed();
        $comments{review_state} = uc($review_type);
    } else {
        $comments{review_state} = 'PENDING';
        print "\n❌ Error submitting review. Check gh CLI output above. Error code: $output\n";
    }
    
    if (defined $temp_file && -e $temp_file) {
        unlink $temp_file;
    }
}

sub cmd_load_comments {
    if (!defined $current_pr) {
        print "Error: No PR selected. Use 'pr <PR#>' first.\n";
        return;
    }

    print "\nFetching submitted review comments for PR #$current_pr...\n";

    my $repo_path_cmd = "gh api repos/{owner}/{repo} --jq '.full_name' 2>/dev/null";
    my $repo_path = `$repo_path_cmd`;
    chomp $repo_path;

    if ($? != 0 || !$repo_path || $repo_path !~ /\//) {
        print "Error: Failed to determine repository path (owner/repo) using 'gh api'. Check your current directory and authentication.\n";
        return;
    }
    
    $repo_path =~ s/^"|"$//g;
    
    my $api_cmd = "gh api repos/$repo_path/pulls/$current_pr/comments --jq '\n+        .[] | {\n+            user: .user.login,\n+            body: .body,\n+            path: .path,\n+            line: .line,\n+            position: .position,\n+            created_at: .created_at\n+        }'";

    my $json_output = `$api_cmd`;
    
    if ($? != 0) {
        print "Error: Failed to fetch comments via gh api. Check permissions and 'gh auth status'.\n";
        return;
    }

    my @comments_data = ();
    foreach my $json_line (split /\n/, $json_output) {
        next unless $json_line =~ /^{/;
        eval {
            push @comments_data, decode_json($json_line);
        };
        if ($@) {
            print "Warning: Failed to parse comment JSON: $@\n";
        }
    }

    if (!@comments_data) {
        print "No submitted positional review comments found for PR #$current_pr.\n";
        return;
    }
    
    @comments_data = sort { 
        $a->{path} cmp $b->{path} || $a->{line} <=> $b->{line} 
    } @comments_data;

    print "\n### 💬 Submitted Comments by Other Reviewers ###\n";
    print "------------------------------------------------------\n";

    my $current_path = "";
    foreach my $c (@comments_data) {
        if ($c->{path} ne $current_path) {
            $current_path = $c->{path};
            print "\nFile: **$current_path**\n";
        }

        my $date_str = substr($c->{created_at}, 0, 10);
        
        print sprintf(" %-15s (Line: %-4s | Pos: %-4s) [%s]\n", 
            $c->{user}, $c->{line}, $c->{position}, $date_str
        );
        my $body_preview = (split /\n/, $c->{body})[0];
        print "    > $body_preview...\n";
    }
    print "------------------------------------------------------\n";
}

sub cmd_load_general_comments {
    if (!defined $current_pr) {
        print "Error: No PR selected. Use 'pr <PR#>' first.\n";
        return;
    }

    print "\nFetching general discussion comments for PR #$current_pr...\n";

    my $cmd = "gh pr view $current_pr --json comments 2>/dev/null";

    my $json_output = `$cmd`;
    
    if ($? != 0) {
        print "Error: Failed to execute 'gh pr view --json comments'.\n";
        return;
    }

    my $data;
    eval {
        $data = decode_json($json_output);
    };

    if ($@ || !defined $data->{comments} || !ref $data->{comments}) {
        print "Error: Failed to parse general comments JSON.\n";
        return;
    }

    my @comments = @{$data->{comments}};

    if (!@comments) {
        print "No general discussion comments found for PR #$current_pr.\n";
        return;
    }
    
    print "\n### 💬 General PR Discussion Comments (" . scalar(@comments) . ") ###\n";
    print "------------------------------------------------------\n";

    @comments = sort { $b->{createdAt} cmp $a->{createdAt} } @comments;

    for my $c (@comments) {
        my $user = $c->{author}->{login} // 'Unknown User';
        my $date_str = substr($c->{createdAt}, 0, 10);
        my $body = $c->{body} // 'No body content.';
        
        print sprintf("\n[%s] Comment by **%s** on %s\n", 
            $c->{id} || 'N/A', $user, $date_str
        );
        
        my @body_lines = split /\n/, $body;
        my $preview_lines = 0;
        
        for my $line (@body_lines) {
            next if $line =~ /^\s*$/ && $preview_lines == 0; 
            print "    > $line\n";
            $preview_lines++;
            last if $preview_lines >= 64;
        }

        print "    > ... (truncated) ...\n" if scalar(@body_lines) > $preview_lines;
    }
    print "------------------------------------------------------\n";
}

sub cmd_show_diffs_ignore_whitespace {
    if (!defined $current_pr) {
        print "Error: No PR selected. Use 'pr <PR#>' first.\n";
        return;
    }
    if (!defined $current_file_name) {
        print "Error: No file selected. Use 'sf <file#>' or '+' first.\n";
        return;
    }

    print "Ensuring PR #$current_pr history is available locally...\n";
    
    my @fetch_cmd = ("git", "fetch", "origin", "pull/$current_pr/head:refs/pr_temp/$current_pr");
    
    print "Executing: @fetch_cmd\n";
    system(@fetch_cmd); 
    
    if ($? != 0) {
        print "\nError: Failed to fetch PR #$current_pr head commits. Cannot proceed with diff.\n";
        return;
    }
    print "Fetch complete.\n";

    print "Fetching base and head commit SHAs...\n";
    
    my $sha_cmd = "gh pr view $current_pr --json baseRefOid,headRefOid 2>/dev/null";
    my $json_output = `$sha_cmd`;

    my $data;
    eval { $data = decode_json($json_output); };
    if ($@ || !defined $data->{baseRefOid} || !defined $data->{headRefOid}) {
        print "Error: Failed to parse commit SHAs from gh CLI output.\n";
        return;
    }
    
    my $base_sha = $data->{baseRefOid};
    my $head_sha = $data->{headRefOid};
    
    print "Diff (ignoring whitespace) for file: **$current_file_name**\n";

    my @diff_cmd_parts = (
        "git",
        "diff",
        "--ignore-all-space",
        "$base_sha",
        "$head_sha",
        "--",
        $current_file_name
    );
    
    system(@diff_cmd_parts);
    
    system("git", "update-ref", "-d", "refs/pr_temp/$current_pr");
}

sub cmd_load_session {
    my $session_file_path = get_session_file_path();

    unless (-e $session_file_path) {
        print "No previous session found.\n";
        return;
    }

    print "Attempting to load previous session from $session_file_path...\n";

    my $data;
    eval {
        local $/;
        open(my $fh, '<', $session_file_path) or die "Could not open file: $!";
        my $json_text = <$fh>;
        close $fh;
        $data = decode_json($json_text);
    };

    if ($@) {
        print "Warning: Failed to load or parse session file: $@\n";
        return;
    }

    my $pr_num = $data->{pr_num} // undef;
    my $file_name = $data->{file_name} // undef;

    if (defined $pr_num) {
        print "Restoring PR #$pr_num.\n";

        cmd_select_pr($pr_num, -1);

        if (defined $file_name && defined $current_pr) {
            my @pr_files = sort keys %files_data;
            my $found_index = 0;

            for my $i (0 .. $#pr_files) {
                if ($pr_files[$i] eq $file_name) {
                    $found_index = $i + 1;
                    last;
                }
            }

            if ($found_index > 0) {
                print "Restoring file: $file_name (index $found_index).\n";
                cmd_select_file($found_index, 1);
            } else {
                print "Warning: File '$file_name' not found in PR \#{$pr_num}'s file list.\n";
            }
        }
    }
}

# --- Chat with Gemini ---
use GeminiConverse qw(new);

sub cmd_gemini_chat {
    my ($arg) = @_;

    my $model         = 'gemini-2.5-flash';
    my $system_prompt =
        'you are a Veteran C++ Architect (ISO/IEC 14882 expert). Your sole function is to review provided code diffs. Your review must be concise, direct, and actionable, adhering strictly to C++17 standards and best practices (RAII, smart pointers, constexpr). Focus on:\n1. **Memory Safety:** Immediately flag any raw pointer use, manual memory management, or potential leaks.\n2. **Performance:** Identify inefficient loops, excessive copying, or unnecessary dynamic allocation.\n3. **Correctness:** Check for threading issues, race conditions, and undefined behavior.\n4. **Design:** Ensure proper use of polymorphism, templates, and adherence to SOLID principles where applicable.\nSuppress any introductory or conversational preambles. Get straight to the review points.';

    unless ($ENV{GEMINI_API_KEY}) {
        print STDERR "FATAL: GEMINI_API_KEY environment variable not set.\n";
        return;
    }

    print "--- Starting Interactive Gemini Chat ---\n";
    print "Model: $model\n";
    print "Persona: '" . substr( $system_prompt, 0, 80 ) . "...'\n";
    print "Type /q or /e to end the conversation.\n\n";

    my $chat = GeminiConverse->new(
        model  => $model,
        system => $system_prompt,
    );

    while (1) {
        print "gemini > ";
        my $user_input = <STDIN>;
        last unless defined $user_input;
        chomp $user_input;
        $user_input =~ s/^\s+|\s+$//g;

        if ($user_input =~ /^\/(q|e|\.)$/i) {
            print "\nSession closed. Goodbye!\n";
            last;
        }

        next unless length $user_input;

        my $reply;
        eval {
            $reply = $chat->reply($user_input);
        };

        if ($@) {
            print STDERR "\n🤖 ERROR: An issue occurred during the API call.\n";
            print STDERR "Details: $@\n\n";
        } elsif (defined $reply) {
            print "🤖 jim: $reply\n\n";
        } else {
            print "🤖 jim: (I received no response from the model.)\n\n";
        }
    }
}

sub cmd_grep_diffs {
    my ($regexp) = @_;

    if (!defined $current_pr) {
        print "Error: No PR selected. Use 'pr <PR#>' first.\n";
        return;
    }

    if (!$regexp) {
        print "Usage: g <regexp>\n";
        return;
    }

    @grep_set = ();
    $current_grep_index = undef;

    my @pr_files = sort keys %files_data;

    print "Searching diffs for **'$regexp'** in " . scalar(@pr_files) . " files...\n";

    for my $i (0 .. $#pr_files) {
        my $file_name = $pr_files[$i];
        my $file_index = $i + 1;

        my ($diff, $err) = get_file_diff_content($file_name);
        next if $err;

        my $match_found = 0;
        foreach my $line (split /\n/, $diff) {
            if ($line =~ /^[+-]/ && $line =~ /$regexp/i) {
                $match_found = 1;
                last;
            }
        }

        if ($match_found) {
            push @grep_set, $file_index;
            print sprintf("  [ %2d ]: %s\n", $file_index, $file_name);
        }
    }

    my $match_count = scalar(@grep_set);

    if ($match_count > 0) {
        print "\nFound **$match_count** file(s) matching '$regexp'.\n";
        $current_grep_index = 1;
        my $first_file_index = $grep_set[0];
        print "Selecting first matching file (Index $first_file_index).\n";
        cmd_select_file($first_file_index, 0);
    } else {
        print "No files found matching '$regexp' in diffs.\n";
    }
}

sub _navigate_grep_set {
    my ($direction) = @_;

    if (!@grep_set) {
        print "No previous 'g' command set. Use 'g <regexp>' first.\n";
        return;
    }

    if (!defined $current_grep_index) {
        $current_grep_index = 1;
    }

    my $new_grep_index = $current_grep_index + $direction;
    my $max_grep_index = scalar(@grep_set);

    if ($new_grep_index < 1) {
        print "Beginning of grep set reached (at file 1).\n";
        return;
    } elsif ($new_grep_index > $max_grep_index) {
        print "End of grep set reached (at file $max_grep_index).\n";
        return;
    }

    $current_grep_index = $new_grep_index;
    my $file_index_to_select = $grep_set[$current_grep_index - 1];

    print "Navigating to file **$current_grep_index/$max_grep_index** in grep set (File index $file_index_to_select).\n";
    cmd_select_file($file_index_to_select, 0);
}

sub cmd_grep_diffs_next { _navigate_grep_set(1); }
sub cmd_grep_diffs_prev { _navigate_grep_set(-1); }

sub cmd_grep_local {
    my ($regexp) = @_;

    if (!defined $current_pr) {
        print "Error: No PR selected. Use 'pr <PR#>' first.\n";
        return;
    }

    if (!$regexp) {
        print "Usage: gl <regexp>\n";
        return;
    }

    @grep_set = ();
    $current_grep_index = undef;

    my @pr_files_sorted = sort @pr_files;

    print "Branch: " . get_current_branch() . "\n";
    print "🔍 Searching **local files** for pattern: **'$regexp'** in " . scalar(@pr_files_sorted) . " files...\n";

    for my $i (0 .. $#pr_files_sorted) {
        my $file_name = $pr_files_sorted[$i];
        my $file_index = $i + 1;

        unless (-f $file_name) {
            print STDERR "Skipping '$file_name': File not found locally.\n";
            next;
        }

        open my $fh, '<', $file_name or do { warn "Could not open '$file_name': $!\n"; next; };

        my $match_found = 0;
        my $line_num = 0;

        while (my $line = <$fh>) {
            $line_num++;
            if ($line =~ /$regexp/i) {
                if (!$match_found) { print "\n-- **$file_name** (Index $file_index) --\n"; }
                $match_found = 1;
                print sprintf("  %4d: %s", $line_num, $line);
            }
        }
        close $fh;

        if ($match_found) { push @grep_set, $file_index; }
    }

    my $match_count = scalar(@grep_set);

    if ($match_count > 0) {
        print "\nFound **$match_count** file(s) matching '$regexp'.\n";
        $current_grep_index = 1;
        my $first_file_index = $grep_set[0];
        print "Selecting first matching file (Index $first_file_index). Use 'g+'/'g-' to navigate.\n";
        cmd_select_file($first_file_index, 1);
    } else {
        print "No files found matching '$regexp' locally.\n";
    }
}

sub cmd_history {
    print "Command History:\n";
    my $start = scalar(@command_history) > 10 ? scalar(@command_history) - 10 : 0;

    for my $i ($start .. $#command_history) {
        printf "  %4d  %s\n", $i + 1, $command_history[$i];
    }
}

sub cmd_select_file_name_regexp {
    my ($regexp) = @_;

    if (!defined $current_pr) {
        print "Error: No PR selected. Use 'pr <PR#>' first.\n";
        return;
    }

    if (!$regexp) {
        print "Usage: f <regexp> or fn <regexp>\n";
        return;
    }

    my @matched_files = ();
    my @pr_files_sorted = sort @pr_files;

    print "Searching file names for pattern: **'$regexp'**...\n";

    for my $i (0 .. $#pr_files_sorted) {
        my $file_name = $pr_files_sorted[$i];
        my $file_index = $i + 1;
        if ($file_name =~ /$regexp/i) { push @matched_files, { index => $file_index, name => $file_name }; }
    }

    my $match_count = scalar(@matched_files);

    if ($match_count > 0) {
        print "\nFound **$match_count** file(s) matching '$regexp':\n";
        foreach my $match (@matched_files) { print sprintf(" %4d : %s\n", $match->{index}, $match->{name}); }
        my $first_match = $matched_files[0];
        my $first_file_index = $first_match->{index};
        print "\nSelecting first matching file (Index $first_file_index).\n";
        cmd_select_file($first_file_index, 1);
    } else {
        print "No files found matching '$regexp' in the PR file list.\n";
    }
}

1;
