# Homebrew cask for Soyla. The live copy lives in the public tap repo ShamsiddinKomil/homebrew-soyla
# (file Casks/soyla.rb there); users install with:  brew install --cask ShamsiddinKomil/soyla/soyla
#
# Soyla is signed with the project's own certificate (hardened runtime) but not notarized by Apple, so the first
# open needs System Settings → Privacy & Security → Open Anyway, once per version (see the caveats below).
#
# Publishing the tap (once, after the v0.3.0 release is on GitHub):
#   1. gh repo create ShamsiddinKomil/homebrew-soyla --public --description "Homebrew tap for Soyla"
#   2. git clone https://github.com/ShamsiddinKomil/homebrew-soyla && mkdir -p homebrew-soyla/Casks
#   3. cp Casks/soyla.rb homebrew-soyla/Casks/soyla.rb, then in that copy set:
#        version "0.3.0"
#        sha256  the first field of Soyla-v0.3.0.zip.sha256 from the release:
#                gh release download v0.3.0 --repo ShamsiddinKomil/soyla --pattern '*.sha256' --output - | cut -d' ' -f1
#   4. In homebrew-soyla: git add Casks/soyla.rb && git commit -m "soyla 0.3.0" && git push
#   5. Check and test as a user (brew only lints casks that sit in a tap):
#        brew tap ShamsiddinKomil/soyla
#        brew style --cask ShamsiddinKomil/soyla/soyla && brew audit --cask --online ShamsiddinKomil/soyla/soyla
#        brew install --cask ShamsiddinKomil/soyla/soyla
# Every later release: repeat step 3 (version + sha256) in the tap and push. Keep this file's placeholders as they are.
cask "soyla" do
  version "X.Y.Z"                 # placeholder: release version without the leading v
  sha256 "REPLACE_WITH_SHA256"    # placeholder: contents of Soyla-vX.Y.Z.zip.sha256 (first field)

  url "https://github.com/ShamsiddinKomil/soyla/releases/download/v#{version}/Soyla-v#{version}.zip"
  name "Soyla"
  desc "Dictation for Uzbek, Russian and English in one sentence"
  homepage "https://github.com/ShamsiddinKomil/soyla"

  depends_on macos: :sonoma # macOS 14+, the same as Package.swift and LSMinimumSystemVersion

  auto_updates true            # Soyla updates itself (Settings → About); brew upgrade leaves it alone

  app "Soyla.app"

  zap trash: [
    "~/Library/Application Support/Soyla",
    "~/Library/Preferences/ai.soyla.app.plist",
    "~/Library/Preferences/ai.soyla.settings.plist",
    "~/Library/Preferences/ai.ovoz.settings.plist", # settings from before the rename
  ]

  caveats <<~EOS
    Soyla is not notarized by Apple. On the first open of each version, macOS blocks it:
    click Done, then System Settings → Privacy & Security → Open Anyway.
  EOS
end
