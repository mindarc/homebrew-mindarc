require "formula"
require_relative "../custom_download_strategy.rb"


class Mindarc < Formula
  homepage "https://www.mindarc.com.au"
  url "https://github.com/mindarc/mindarc-cli/releases/download/v1.0.1/mindarc-v1.0.1-darwin-arm64.tar.gz", :using => GitHubPrivateRepositoryReleaseDownloadStrategy
  sha256 "8d231a552eb6b7e405b539a48157dc3c539a1e6112f34f4cc0c7770f5919f668"
  head "https://github.com/mindarc/mindarc-cli.git"
  version "1.0.1"

  def install
    bin.install "mindarc"
  end

  test do
      system "#{bin}/mindarc --help"
  end
end
