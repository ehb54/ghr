#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;

# --- Default Values ---
my $mode = 'reviews'; # Default mode: 'reviews' (PRs)
my $state_flag = 'open';
my $repo_arg = '';
my $reviewer_arg = '@me';
my $mentions_flag;
my $help;
my $limit = 100;

# --- Process Command Line Arguments ---
GetOptions(
    'help'         => \$help,
    'state=s'      => \$state_flag,
    'repo=s'       => \$repo_arg,
    'reviewer=s'   => \$reviewer_arg,
    'mentions'     => \$mentions_flag, # New flag: if present, mode changes
    'limit=i'      => \$limit,
) or pod2usage(2);

pod2usage(1) if $help;

# --- Determine Mode and Argument ---
if ($mentions_flag) {
    $mode = 'mentions';
    # Use the --reviewer argument value for mentions, if provided, otherwise default to @me
    $reviewer_arg = $reviewer_arg || '@me'; 
}

# --- Build the gh Command ---

my $command = '';
my $jq_expression = '';

# Shared qualifiers/flags
my $shared_flags = "--limit $limit ";

# 1. State/Filter Argument
if (lc($state_flag) ne 'any') {
    $shared_flags .= "--state $state_flag ";
}

# 2. Sorting (Oldest first)
# The default sort is 'best-match'. We want to sort by 'updated' (last updated), ascending (oldest first).
$shared_flags .= "--sort updated --order asc ";

# --- Construct Command based on Mode ---

if ($mode eq 'reviews') {
    # Mode: REVIEW REQUESTS (Original PR search)
    $command = "gh search prs ";
    $command .= $shared_flags;
    $command .= "--review-requested \"$reviewer_arg\" ";
    $command .= "--json title,url,repository,updatedAt ";
    
    # Use repo qualifier if --repo is provided
    if ($repo_arg) {
        $command .= "repo:$repo_arg ";
    }
    
    # JQ for PRs: Extract name, title, and remove parentheses from URL
    $jq_expression = '
        .[] |
        .updatedAt as $date | 
        ($date | sub("Z$"; "") | sub("T"; " ")) as $iso_date |
        "[\($iso_date)] - " + 
        .repository.name + 
        ": \(.title) \(.url)"
    ';

} elsif ($mode eq 'mentions') {
    # Mode: MENTIONS (New Issues/PR search)
    $command = "gh search issues ";
    $command .= $shared_flags;
    $command .= "--mentions \"$reviewer_arg\" ";
    $command .= "--json title,url,repository,number,updatedAt ";

    # Use repo qualifier if --repo is provided
    if ($repo_arg) {
        $command .= "repo:$repo_arg ";
    }

    # JQ for Issues/PRs: Extract name, number, title
    $jq_expression = '
        .[] | 
        .updatedAt as $date | 
        ($date | sub("Z$"; "") | sub("T"; " ")) as $iso_date |
        "[\($iso_date)] - " + 
        .repository.name + 
        ": #\(.number) \(.title) \(.url)"
    ';
}

$command .= "--jq '$jq_expression'";

# --- Execute and Post-Process ---

# Execute the gh command
my $output = `$command`;

# Check for errors from gh command execution
if ($?) {
    print STDERR "Error executing GitHub CLI command:\n$command\n";
    print STDERR $output;
    exit 1;
}

print $output;

# --- Pod Documentation (for --help) ---
__END__

=head1 NAME

gh_reviews.pl - List GitHub PRs or Issues/PRs where review/mention was requested.

=head1 SYNOPSIS

gh_my_reviews.pl [options]

=head1 OPTIONS

=over 8

=item B<--help>

Display this help message.

=item B<--mentions>

Switch the script to search for Issues and PRs where you have been **mentioned** (uses the C<--reviewer> argument as the user to search for). This is the "mentions" mode.
The default mode is to search for Pull Requests where a review was requested.

=item B<--state> I<arg>

Specify the state of the items. Defaults to 'open'.
Use 'closed', 'merged', or 'any' (to remove the state restriction).

=item B<--repo> I<arg>

Restrict the search to a specific repository or organization (e.g., 'owner/repo' or 'owner/*').

=item B<--reviewer> I<arg>

Specify the user to search for. Defaults to C<@me> (the current authenticated user).
This applies to both C<review-requested> (default mode) and C<mentions> (with C<--mentions> flag).

=item B<--limit> I<arg>

Specify the maximum number of results to fetch. Defaults to 100.

=back

=head1 DESCRIPTION

This script wraps the GitHub CLI's C<gh search> commands to find items requiring your attention. Results are always sorted by the time they were last updated, oldest first.

=head1 EXAMPLES

 # Default: Open PRs where your review is requested, oldest first
 ./gh_my_reviews.pl

 # Open Issues/PRs where you have been mentioned, oldest first
 ./gh_my_reviews.pl --mentions
 
 # Closed PRs where another user was requested to review, in a specific repo
 ./gh_my_reviews.pl --state closed --repo 'my-org/my-app' --reviewer 'johndoe'

=cut
