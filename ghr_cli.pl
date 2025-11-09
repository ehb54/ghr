use strict;
use warnings;
use FindBin '$Bin';
use lib $Bin;

my $utils_file = "$Bin/ghr_utils.pl";
do $utils_file or die "Failed to load $utils_file: $! $@\n";

my $cmds_file = "$Bin/ghr_cmds.pl";
do $cmds_file or die "Failed to load $cmds_file: $! $@\n";

sub get_prompt {
    my $prompt = '-'x120 . "\nghr";

    if (defined $current_pr) {
        $prompt .= " \#$current_pr";

        if (defined $current_file_name) {
            my $total_files = scalar(@pr_files) || scalar(keys %files_data) || 0;
            my $current_index = $current_file_index // 0;
            my $pct = $total_files ? 100 * ($current_index / $total_files) : 0;
            $prompt .= sprintf(" [%d/%d | %.1f%%] %s", $current_index, $total_files, $pct, $current_file_name);
        }
    }

    $prompt .= " > ";
    return $prompt;
}

sub process_history_input {
    my ($input) = @_;

    if ($input =~ /^\s*(!\d*|!!)(:\S*)?\s*$/) {
        my $history_spec = $1;
        my $modifier = $2 || '';

        my $history_size = scalar(@command_history);
        my $history_index;

        if ($history_spec eq '!!') {
            $history_index = $history_size;
        } elsif ($history_spec =~ /^!(\d+)$/) {
            $history_index = $1;
        }

        if ($history_index < 1 || $history_index > $history_size) {
            print STDERR "History error: Event number $history_index not found.\n";
            return undef;
        }

        my $resolved_command = $command_history[$history_index - 1];

        if ($modifier eq ':p') {
            print ">> $resolved_command\n";
            return undef;
        }

        print ">> $resolved_command\n";
        return $resolved_command;
    }

    return $input;
}

sub main {
    load_history();
    while (1) {
        print get_prompt();

        my $raw_input = <STDIN>;
        last unless defined $raw_input;

        chomp $raw_input;
        my $user_input = $raw_input;
        $user_input =~ s/^\s+|\s+$//g;

        next unless length $user_input;

        my $executed_command = process_history_input($user_input);

        if (!defined $executed_command) {
            if ($user_input =~ /^\s*h(istory)?\s*$/i) {
                cmd_history();
            }
            next;
        }

        my @parts = split /\s+/, $executed_command, 2;
        my $cmd = lc $parts[0];
        my $args = $parts[1] // '';

        if (($cmd eq '+' || $cmd eq '-') && $args eq '') {
            $args = $cmd;
        }

        if (my $sub = $COMMANDS{$cmd}) {
            eval { $sub->($args); };
            if ($@) { print "Command Error: $@\n"; }
        } else {
            print "Unknown command: '$cmd'. Type 'h' for help.\n";
        }

        if ($user_input !~ /^\s*(h(istory)?|!\d*|!!)(:\S*)?\s*$/i) {
            push @command_history, $executed_command;
            if (scalar(@command_history) > $history_max_size) { shift @command_history; }
        }
    }
    save_history();
    print "\nExiting.\n";
}

# Run checks and start interactive session
check_gh_auth();
cmd_load_session();
main();

1;
