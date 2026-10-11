# Builds this repository's SwiftPM package in release mode and installs the
# `siri-ai` CLI. Kept minimal on purpose — see docs/guide/getting-started.md
# for the user-facing install instructions this formula backs.
#
# NOTE: no version tags exist in this repository yet (releases are pushed as
# git tags per docs/guide/release-workflow.md), so the formula defaults to a
# head build until the first tag lands. Pin the `url`-with-`tag`/`revision`
# form at that point, then add `sha256` computed by brew (audit says so).
class SiriAi < Formula
  desc "Apple Intelligence and the Siri AI app from your terminal"
  homepage "https://github.com/RabinApps/siri-ai"
  # no url/tag yet — first release pending; brew builds from head by default
  license "MIT"
  head "https://github.com/RabinApps/siri-ai.git", branch: "main"

  depends_on xcode: ["26.0", :build]
  depends_on macos: :tahoe # Apple Intelligence requires macOS 26+

  def install
    system "swift", "package", "resolve", "--package-path", buildpath, "--disable-sandbox"
    # SwiftPM's own sandbox cannot nest inside Homebrew's build sandbox
    # (SwiftPM plugins/macros) — mirror the homebrew-core mockolo approach.
    system "swift", "build", "--package-path", buildpath, "-c", "release", "--disable-sandbox"
    bin.install ".build/release/siri_ai" => "siri-ai"
  end

  test do
    system bin/"siri-ai", "--help"
  end
end
