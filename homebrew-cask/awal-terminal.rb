cask "awal-terminal" do
  version "0.14.1"
  sha256 "172d819355025182012958beaff32ec054feec4137c95ea65879c1ae0ad5b8bb"

  url "https://github.com/AwalTerminal/Awal-terminal/releases/download/v#{version}/AwalTerminal.zip"
  name "Awal Terminal"
  desc "LLM-native terminal emulator for macOS"
  homepage "https://awalterminal.github.io/Awal-terminal/"

  depends_on macos: ">= :sonoma"

  app "AwalTerminal.app"

  zap trash: [
    "~/.config/awal",
  ]
end
