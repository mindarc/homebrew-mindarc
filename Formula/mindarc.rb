require "formula"
require_relative "../custom_download_strategy.rb"

class Mindarc < Formula
  homepage "https://www.mindarc.com.au"
  url "https://github.com/mindarc/mindarc-devops/releases/download/v1.0.0/mindarc-cli-v1.0.0.tar.gz", :using => GitHubPrivateRepositoryReleaseDownloadStrategy
  sha256 "210a619c56a2c523b8c80b88c601926a4443d7d633aab1be3766cc61fbc38dec"
  head "https://github.com/mindarc/mindarc-cli.git"
  version "1.0.0"

  def install
    bin.install "mindarc"
  end

  test do
      system "#{bin}/mindarc --help"
  end
end
