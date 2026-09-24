class Boyd < Formula
  desc "Boyd environment CLI for Ronintech engineers"
  homepage "https://github.com/ronintech-ai/boyd-infra"
  version "0.1.0"
  license "MIT"

  depends_on "awscli"
  depends_on "kubernetes-cli"
  depends_on "helm"
  depends_on "argocd"
  depends_on "kind"
  depends_on "jq"
  depends_on "just"
  depends_on "gh"
  depends_on "git"

  def install
    pkg = Pathname(__dir__).join("..", "boyd-cli", version.to_s, "scripts")
    odie "missing vendored scripts at #{pkg}" unless pkg.directory?

    libexec.install pkg.children
    (bin/"boyd").write <<~SHELL
      #!/bin/bash
      exec "#{libexec}/boyd" "$@"
    SHELL
  end

  def caveats
    <<~EOS
      Onboarding (after GitHub org invite + SSH key):
        boyd github
        boyd onboard

      Refresh AWS/VPN only:
        boyd setup
        boyd status
    EOS
  end

  test do
    assert_match "boyd github", shell_output("#{bin}/boyd help")
  end
end
