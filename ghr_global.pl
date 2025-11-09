use strict;
use warnings;

# Plain globals file — intentionally not a package so it can be required
# inline into scripts and set 'our' variables into the main namespace.

# --- Shared Global State ---
our $current_pr = undef;
our $current_file_index = undef;  # 1-based index from 'lf'
our $current_file_name = undef;   # Actual file path
our @pr_files = ();              # Array of file names for the current PR
our %comments = (
    'global' => [],     # Array of global comments: {text => ..., status => 'local'|'pushed'}
    'files'  => {},     # Hash: 'path/to/file.txt' => [ {line => ..., pos => ..., text => ..., status => 'local'|'pushed'}, ... ]
    'review_state' => undef  # 'approve' | 'request_changes'
);
our %files_data = ();
our @grep_set = ();            # Array of 1-based file indices that match the last 'g' regexp
our $current_grep_index;       # 1-based index into @grep_set
our @command_history = ();     # Array to store executed commands
our $history_max_size = 100;   # Maximum number of commands to store
our %COMMANDS = ();           # Command dispatch table

1;