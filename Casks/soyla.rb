# Homebrew cask TEMPLATE for Soyla. Not published yet: it needs a tap repo named
# "homebrew-soyla" (so users run `brew tap <owner>/soyla`). Copy this file to
# Casks/soyla.rb in that repo and fill in the two placeholders after each release.
#
# Soyla is signed with the project's own certificate (hardened runtime) but not notarized by Apple, so Gatekeeper
# blocks a normal first open. Users install with:  brew install --cask --no-quarantine <owner>/soyla/soyla
cask "soyla" do
  version "X.Y.Z"                 # placeholder: release version without the leading v
  sha256 "REPLACE_WITH_SHA256"    # placeholder: contents of Soyla-vX.Y.Z.zip.sha256 (first field)

  url "https://github.com/ShamsiddinKomil/soyla/releases/download/v#{version}/Soyla-v#{version}.zip"
  name "Soyla"
  desc "Dictation for Uzbek, Russian and English in one sentence"
  homepage "https://github.com/ShamsiddinKomil/soyla"

  depends_on macos: ">= :sonoma" # placeholder: match the app's real minimum macOS

  app "Soyla.app"

  zap trash: [
    "~/Library/Application Support/Soyla",
  ]
end
