# Homebrew cask for Soyla. The live copy lives in the public tap repo ShamsiddinKomil/homebrew-soyla
# (file Casks/soyla.rb there); users install with:  brew install --cask ShamsiddinKomil/soyla/soyla
#
# Soyla is signed with the project's own certificate (hardened runtime) but not notarized by Apple, so the first
# open needs System Settings → Privacy & Security → Open Anyway, once per version (see the caveats below).
#
# The tap exists (created 2026-10-26; this repo's cask is the template, the tap holds the live copy). Every release:
#   1. In a clone of ShamsiddinKomil/homebrew-soyla, copy the body of this file (from `cask "soyla" do`, without
#      this header) to Casks/soyla.rb and set, dropping the placeholder comments:
#        version "X.Y.Z"
#        sha256  "<first field of Soyla-vX.Y.Z.zip.sha256>":
#                gh release download vX.Y.Z --repo ShamsiddinKomil/soyla --pattern '*.sha256' --output - | cut -d' ' -f1
#   2. brew style --fix Casks/soyla.rb   (ruby -c is not enough; it found 5 offenses on the first copy)
#   3. git add Casks/soyla.rb && git commit -m "soyla X.Y.Z" && git push
#   4. Check and test as a user (Homebrew 7 audits only trusted taps; install needs no trust step):
#        brew tap ShamsiddinKomil/soyla && brew trust --cask shamsiddinkomil/soyla/soyla
#        brew audit --cask --online ShamsiddinKomil/soyla/soyla
#        brew install --cask --appdir="$(mktemp -d)" ShamsiddinKomil/soyla/soyla && brew uninstall --cask soyla
# Keep this file's placeholders as they are.
cask "soyla" do
  version "X.Y.Z" # placeholder: release version without the leading v
  sha256 "REPLACE_WITH_SHA256" # placeholder: contents of Soyla-vX.Y.Z.zip.sha256 (first field)

  url "https://github.com/ShamsiddinKomil/soyla/releases/download/v#{version}/Soyla-v#{version}.zip"
  name "Soyla"
  desc "Dictation for Uzbek, Russian and English in one sentence"
  homepage "https://github.com/ShamsiddinKomil/soyla"

  auto_updates true # Soyla updates itself (Settings → About); brew upgrade leaves it alone
  depends_on macos: :sonoma # macOS 14+, the same as Package.swift and LSMinimumSystemVersion

  app "Soyla.app"

  zap trash: [
    "~/Library/Application Support/Soyla",
    "~/Library/Preferences/ai.ovoz.settings.plist", # settings from before the rename
    "~/Library/Preferences/ai.soyla.app.plist",
    "~/Library/Preferences/ai.soyla.settings.plist",
  ]

  caveats <<~EOS
    Soyla is not notarized by Apple. On the first open of each version, macOS blocks it:
    click Done, then System Settings → Privacy & Security → Open Anyway.
  EOS
end
