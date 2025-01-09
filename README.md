# bw-fzf

A Bitwarden cli wrapper with fzf

## Requirements

- [`bitwarden-cli`](https://github.com/bitwarden/clients/tree/main/apps/cli)
- [`fzf`](https://github.com/junegunn/fzf)
- [`jq`](https://github.com/jqlang/jq)
- [`oathtool`](https://www.nongnu.org/oath-toolkit/) (optional, for OTP code generation)
- [`xclip`](https://github.com/astrand/xclip) or [`wl-copy`](https://github.com/bugaevc/wl-clipboard) (optional, for copying items to clipboard)

## Installation

### Clone the Repository

```sh
git clone https://github.com/radityaharya/bw-fzf.git
cd bw-fzf
```

Make sure the script is executable:

```sh
chmod +x bw-fzf.sh
```

If you want to make the script available globally, you can install it by running:

```sh
sudo bw-fzf.sh --install
```

## Usage

Setup Bitwarden CLI:
```sh
bw login
```

optionally, for self-hosted Bitwarden:
```sh
bw config server https://your.bitwarden.domain
bw login
```

Run the script:

```sh
./bw-fzf.sh
```

### What It Does

1. Prompts you for your Bitwarden password.
2. Unlocks your Bitwarden vault.
3. Loads all your Bitwarden items.
4. Uses `fzf` to allow you to search and preview items interactively.

### Keyboard Shortcuts

- Type to search for items.
- Use arrow keys or `Ctrl+N`/`Ctrl+P` to navigate through items.

## Note

Ensure you have `bitwarden-cli` (`bw`), `fzf`, and `jq` installed. You can install them via your package manager:

### For Ubuntu

```sh
sudo snap install bw
sudo apt install fzf jq
```

### For MacOS

```sh
brew install bitwarden-cli fzf jq
```

### For Other Systems

Refer to [Bitwarden Cli](https://github.com/bitwarden/clients/tree/main/apps/cli) for installation instructions.

### OTP Code Generation
OTP code generation is supported, it uses `oathtool` to generate the code, and falls back to `bw get totp` if `oathtool` is not available.

To install `oathtool`:
```sh
sudo apt install oathtool
```

### Security

Please remember to keep your terminal secure when running this script, as sensitive information such as passwords and OTP codes will be displayed in plain text.
