cask "awal-terminal" do
  version "0.14.0"
  sha256 "62ef5afa7b77f25daea86c254217112c200141751ad815f0e00d50b35aea7dca"

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
