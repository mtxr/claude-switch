class Csw < Formula
  desc "Switch between Claude Code and Claude Desktop accounts"
  homepage "https://github.com/mtxr/claude-switch"
  version "@VERSION@"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/mtxr/claude-switch/releases/download/v@VERSION@/csw-aarch64-apple-darwin"
      sha256 "@SHA_AARCH64_DARWIN@"
    end
    on_intel do
      url "https://github.com/mtxr/claude-switch/releases/download/v@VERSION@/csw-x86_64-apple-darwin"
      sha256 "@SHA_X86_64_DARWIN@"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/mtxr/claude-switch/releases/download/v@VERSION@/csw-aarch64-unknown-linux-musl"
      sha256 "@SHA_AARCH64_LINUX@"
    end
    on_intel do
      url "https://github.com/mtxr/claude-switch/releases/download/v@VERSION@/csw-x86_64-unknown-linux-musl"
      sha256 "@SHA_X86_64_LINUX@"
    end
  end

  def install
    bin.install Dir["csw-*"].first => "csw"
    chmod 0755, bin/"csw"
    bin.install_symlink "csw" => "claude-switch"
    (bash_completion/"csw").write Utils.safe_popen_read(bin/"csw", "completion", "bash")
    (zsh_completion/"_csw").write Utils.safe_popen_read(bin/"csw", "completion", "zsh")
    (fish_completion/"csw.fish").write Utils.safe_popen_read(bin/"csw", "completion", "fish")
    (man1/"csw.1").write Utils.safe_popen_read(bin/"csw", "man")
  end

  def caveats
    <<~EOS
      To switch profiles per directory, add this to your shell rc:
        eval "$(csw hook zsh)"   # or: eval "$(csw hook bash)"
      The hook also registers shell completions.

      An interactive picker is built in. Install sk or fzf for fuzzy search:
        brew install sk
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/csw --version")
  end
end
