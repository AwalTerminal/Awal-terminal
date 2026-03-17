cask "awal-terminal" do
  version "0.14.2"
  sha256 "bb54c51ffda92d86bc35e3bef07e77efbec0bfcc787a15a746b6e3ba3077baf1"

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
