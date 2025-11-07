# ghr: The Command-Line GitHub Pull Request Reviewer

[](https://www.google.com/search?q=LICENSE)
[](https://cli.github.com/)

**ghr** is a powerful Perl-based command-line utility designed to streamline the process of reviewing large GitHub Pull Requests. It enables you to quickly navigate files, view diffs (with and without whitespace changes), and track line-specific comments, all from within your terminal.

-----

## ✨ Features

  * **Interactive Session:** Persistent state tracking for the current PR, file, and local comments. Command history.
  * **Efficient Navigation:** Use simple commands (`+`, `-`) to jump between changed files.
  * **File Selection:** Select files by index or full name (`sf 5`, `sf file.c`).
  * **Diff Viewing:** View diffs with standard output (`sd`) or with whitespace changes ignored (`sdiw`).
  * **Comment Tracking:** Add positional comments (`ca`) and view pending comments (`rs`, `lc`).
  * **Full Review Submission:** Submit a complete review with comments, marked as **APPROVE** or **REQUEST\_CHANGES** (`accept`, `reject`).
  * **Contextual Prompt:** The prompt always shows the current PR, file index, and file name.
  * **AI Assistance:** Access the Gemini model directly to ask questions or get contextual feedback on the current file's content or diff.

-----

## 🚀 Installation & Setup

**ghr** is a standalone Perl script but relies heavily on the official **GitHub CLI (`gh`)** being installed and authenticated.

### Prerequisites

1.  **Perl:** Ensure you have a working Perl interpreter (most systems include this).
2.  **GitHub CLI:** Install and authenticate the GitHub CLI.
    ```bash
    # Check installation
    gh --version
    # Ensure you are authenticated
    gh auth status
    ```
3.  **Required Perl Modules:**
    ```bash
    cpan JSON
    ```
4.  **Gemini API Key:** Set the `GEMINI_API_KEY` environment variable for AI features (`ajim`).
    ```bash
    export GEMINI_API_KEY="YOUR_API_KEY_HERE"
    ```

### Running ghr

1.  Clone a Git repository that has open Pull Requests.
2.  Place the `ghr` script in a convenient location (e.g., inside your project directory).
3.  Start the interactive session:
    ```bash
    perl ghr
    ```

-----

## 📖 Usage and Commands

All commands are executed from the `ghr` interactive prompt.

### ⚙️ Session Commands

| Command | Description | Example |
| :--- | :--- | :--- |
| `pr <#>` | Select and load the files for a specific Pull Request. | `pr 301` |
| `lpr` | List your current open Pull Requests. | `lpr` |
| `?` | Display the list of available commands. | `?` |
| `h` | Show command history. | `h` |
| `q` | Quit the application. | `q` |
| `!!` | repeat previous command. | `!!` |
| `!n` | repeat command from history. | `!27` |

### 📁 File Navigation & Viewing

| Command | Description | Example |
| :--- | :--- | :--- |
| `lf` | List all files in the current PR. | `lf` |
| `fn <index>` | Select a file by its index number (from `lf` list). | `fn 5` |
| `f  <name>` | Select a file by its name regex. | `f \.h$` |
| **`+`** | Move to and view the **next** file in the PR. | `+` |
| **`-`** | Move to and view the **previous** file in the PR. | `-` |
| `g  <regexp>` | grep diffs | `g qregexp.rx\D` |
| `gl  <regexp>` | grep local files | `g qregexp.rx\D` |
| `g+` | select next file from last grep. | `g+` |
| `g-` | select previous file from last grep. | `g+` |
| `dd` | Show the standard Git diff for the currently selected file. | `dd` |
| **`ddiw`** | Show the diff **ignoring whitespace** changes. | `ddiw` |
| `do` | Show the **original** file content (before changes). | `do` |
| `dn` | Show the **new** file content (with changes). | `dn` |
| `ajim` | **Ask Gemini** a question about the current file, its diff, or a general coding topic. | `ajim` |

### 💬 Commenting and Review

| Command | Description | Example |
| :--- | :--- | :--- |
| `ca <line> <comment>` | **Add** a positional comment to the current file. | `ca 12` |
| `cd <pos>` | **Delete** a local comment by its position index (from `rs`). | `cd 1` |
| `lc` | Load and display all **submitted positional review comments** from other reviewers. | `lc` |
| `lgc` | Load and display all **general PR discussion comments** (e.g., CI/Linter reports). | `lgc` |
| `rs` | Show a **Review Summary** of all locally tracked comments. | `rs` |
| `cp` | **Push** all pending local comments to the PR as a draft review. | `cp` |

### ✅ Final Submission

| Command | Description | Example |
| :--- | :--- | :--- |
| `accept` | **Submit** the review with all pending comments as **APPROVED**. | `accept` |
| `reject` | **Submit** the review with all pending comments as **REQUEST\_CHANGES**. | `reject` |

-----

## 🤝 Contribution

Feel free to fork the repository and contribute\! We welcome bug reports and suggestions for new features.

-----

## ⚖️ License

This project is licensed under the MIT License - see the `LICENSE` file for details.
